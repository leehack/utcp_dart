import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../support/fixtures.dart';
import '../../support/streaming.dart';

void main() {
  late UtcpClient caller;
  setUpAll(() async => caller = await bareClient());
  tearDownAll(() => caller.close());

  SseCallTemplate template([JsonMap fields = const {}]) =>
      SseCallTemplate.fromJson({
        'call_template_type': 'sse',
        'url': 'https://api.example.com/events',
        ...fields,
      });

  SseCommunicationProtocol protocolFor(
    MockClientStreamHandler handler, {
    Duration handshakeTimeout = const Duration(seconds: 30),
    int maxEventChars = 16 * 1024 * 1024,
  }) => SseCommunicationProtocol(
    transport: mockTransport(handler),
    handshakeTimeout: handshakeTimeout,
    maxEventChars: maxEventChars,
  );

  /// Collects the payloads yielded for a stream made of [parts].
  Future<Object?> collect(
    List<Object> parts, {
    JsonMap fields = const {},
    int maxEventChars = 16 * 1024 * 1024,
  }) => protocolFor(
    (request, body) async => streamedResponse(parts),
    maxEventChars: maxEventChars,
  ).callTool(caller, 'm.events', const {}, template(fields));

  group('wire format', () {
    test('multi-line data is joined, and JSON data is decoded', () async {
      expect(
        await collect([
          'data: {"a":\ndata: 1}\n\n',
          'data: first\ndata:second\ndata\n\n',
          'data: 42\n\n',
        ]),
        [
          {'a': 1},
          'first\nsecond\n',
          42,
        ],
      );
    });

    test('only one leading space is stripped from a value', () async {
      expect(await collect(['data:  two\n\n', 'data:none\n\n']), [
        ' two',
        'none',
      ]);
    });

    test('comments, unknown fields and empty blocks yield nothing', () async {
      expect(
        await collect([
          ': keep-alive\n\n',
          'bogus: x\n\n',
          '\n\n\n',
          ': note\nevent: e\ndata: kept\n\n',
          'id: 7\n\n',
          'retry: 10\n\n',
          'event: only-type\n\n',
        ]),
        ['kept'],
      );
    });

    test('CRLF, CR and LF line endings are all accepted', () async {
      expect(
        await collect(['data: a\r\n\r\ndata: b\r\rdata: c\n\ndata: d\r\n\n']),
        ['a', 'b', 'c', 'd'],
      );
    });

    test('chunk boundaries may split lines, CRLF pairs and UTF-8', () async {
      final bytes = utf8.encode('data: 한글\r\n\r\ndata: x\r\n\r\n');
      // Every possible two-chunk split, including inside the multi-byte
      // characters and between CR and LF.
      for (var cut = 1; cut < bytes.length; cut++) {
        expect(await collect([bytes.sublist(0, cut), bytes.sublist(cut)]), [
          '한글',
          'x',
        ], reason: 'split at byte $cut');
      }
      expect(
        await collect([
          for (final byte in bytes) [byte],
        ]),
        ['한글', 'x'],
      );
    });

    test('a CR at a chunk end followed by a non-LF ends one line', () async {
      expect(await collect(['data: a\r', '\rdata: b\n\n']), ['a', 'b']);
    });

    test('a leading byte order mark is ignored', () async {
      expect(
        await collect([
          [0xEF, 0xBB],
          [0xBF, ...utf8.encode('data: x\n\n')],
        ]),
        ['x'],
      );
    });

    test('an event left unterminated at the end is discarded', () async {
      expect(await collect(['data: done\n\n', 'data: partial\n']), ['done']);
    });

    test('an event over the size limit is a protocol error', () async {
      expect(
        collect(['data: ${'x' * 64}'], maxEventChars: 32),
        throwsA(isA<SseProtocolException>()),
      );
      expect(
        collect(['data: 1234\n', 'data: 5678\n' * 4], maxEventChars: 32),
        throwsA(isA<SseProtocolException>()),
      );
      expect(
        await collect(['data: 1234\n\n' * 8], maxEventChars: 32),
        hasLength(8),
      );
    });
  });

  group('event_type', () {
    const stream = [
      'event: update\ndata: 1\n\n',
      'data: 2\n\n',
      'event: message\ndata: 3\n\n',
      'event:\ndata: 4\n\n',
      'event: other\ndata: 5\n\n',
    ];

    test('filters events; an event without a type is "message"', () async {
      expect(await collect(stream, fields: {'event_type': 'update'}), [1]);
      expect(await collect(stream, fields: {'event_type': 'message'}), [
        2,
        3,
        4,
      ]);
    });

    test('unset yields every event', () async {
      expect(await collect(stream), [1, 2, 3, 4, 5]);
    });
  });

  group('streaming', () {
    test('yields each event as it arrives', () async {
      final body = ControlledBody();
      final protocol = protocolFor((request, _) async => body.response());
      final received = <Object?>[];
      final first = Completer<void>();
      final done = protocol
          .callToolStreaming(caller, 'm.events', const {}, template())
          .listen((event) {
            received.add(event);
            if (!first.isCompleted) first.complete();
          })
          .asFuture<void>();
      body.add('data: 1\n');
      body.add('\n');
      await first.future;
      expect(received, [1]);
      body.add('data: 2\n\n');
      await body.close();
      await done;
      expect(received, [1, 2]);
    });

    test('cancelling a quiet stream closes the response at once', () async {
      final body = ControlledBody();
      final protocol = protocolFor((request, _) async => body.response());
      final events = protocol.callToolStreaming(
        caller,
        'm.events',
        const {},
        template(),
      );
      final subscription = events.listen(null);
      body.add('data: 1\n\n');
      await pumpEventQueue();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await body.cancelled.future.timeout(const Duration(seconds: 1));
    });

    test(
      'cancelling during the handshake releases the late response',
      () async {
        final release = Completer<void>();
        final requested = Completer<void>();
        final body = ControlledBody();
        final protocol = protocolFor((request, _) async {
          requested.complete();
          await release.future;
          return body.response();
        });
        final subscription = protocol
            .callToolStreaming(caller, 'm.events', const {}, template())
            .listen(null);
        await requested.future;
        final cancelled = subscription.cancel();
        release.complete();
        await cancelled.timeout(const Duration(seconds: 1));
        await body.cancelled.future.timeout(const Duration(seconds: 1));
      },
    );

    test('taking the first events stops the call', () async {
      final body = ControlledBody();
      final protocol = protocolFor((request, _) async => body.response());
      body
        ..add('data: 1\n\n')
        ..add('data: 2\n\n');
      expect(
        await protocol
            .callToolStreaming(caller, 'm.events', const {}, template())
            .first,
        1,
      );
      await body.cancelled.future.timeout(const Duration(seconds: 1));
    });
  });

  group('errors while opening', () {
    test('4xx and 5xx fail with the status and server reason', () async {
      for (final status in [401, 404, 503]) {
        final protocol = protocolFor(
          (request, _) async => streamedResponse(
            ['{"error":"nope $status"}'],
            status: status,
            contentType: 'application/json',
          ),
        );
        await expectLater(
          protocol.callTool(caller, 'm.events', const {}, template()),
          throwsA(
            isA<UtcpHttpException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.message, 'message', contains('nope')),
          ),
        );
      }
    });

    test('a response that is not an event stream is rejected', () async {
      for (final type in ['application/json', 'text/event-stream-x', '']) {
        final body = ControlledBody();
        final protocol = protocolFor(
          (request, _) async => body.response(contentType: type),
        );
        await expectLater(
          protocol.callTool(caller, 'm.events', const {}, template()),
          throwsA(isA<SseProtocolException>()),
        );
        await body.cancelled.future.timeout(const Duration(seconds: 1));
      }
    });

    test('a media type with parameters is accepted', () async {
      final protocol = protocolFor(
        (request, _) async => streamedResponse([
          'data: ok\n\n',
        ], contentType: 'Text/Event-Stream; charset=utf-8'),
      );
      expect(
        await protocol.callTool(caller, 'm.events', const {}, template()),
        ['ok'],
      );
    });

    test('a stalled handshake or error body times out', () async {
      final protocol = protocolFor(
        (request, _) => Completer<http.StreamedResponse>().future,
        handshakeTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        protocol.callTool(caller, 'm.events', const {}, template()),
        throwsA(
          isA<UtcpException>().having((e) => e.message, 'm', contains('Timed')),
        ),
      );
      final stalled = ControlledBody();
      final errorBody = protocolFor(
        (request, _) async => http.StreamedResponse(
          stalled.controller.stream,
          500,
          headers: {'content-type': 'application/json'},
        ),
        handshakeTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        errorBody.callTool(caller, 'm.events', const {}, template()),
        throwsA(
          isA<UtcpException>().having((e) => e.message, 'm', contains('Timed')),
        ),
      );
      await stalled.cancelled.future.timeout(const Duration(seconds: 1));
    });
  });

  group('reconnect', () {
    Stream<List<int>> dropping(String text) async* {
      yield utf8.encode(text);
      throw http.ClientException('Connection closed while receiving data');
    }

    http.StreamedResponse dropAfter(String text) => http.StreamedResponse(
      dropping(text),
      200,
      headers: {'content-type': 'text/event-stream'},
    );

    test('resumes with Last-Event-ID after the server retry delay', () async {
      final requests = <http.BaseRequest>[];
      final protocol = protocolFor((request, _) async {
        requests.add(request);
        return requests.length == 1
            ? dropAfter('retry: 1\nid: 1\ndata: a\n\n')
            : streamedResponse(['id: 2\ndata: b\n\n']);
      });
      // The template's own delay would outlast the test; retry: 1 wins.
      expect(
        await protocol.callTool(
          caller,
          'm.events',
          const {},
          template({'retry_timeout': 600000}),
        ),
        ['a', 'b'],
      );
      expect(requests, hasLength(2));
      expect(requests.first.headers.containsKey('Last-Event-ID'), isFalse);
      expect(requests.last.headers['Last-Event-ID'], '1');
    });

    test('an empty id resets the last event ID', () async {
      final requests = <http.BaseRequest>[];
      final protocol = protocolFor((request, _) async {
        requests.add(request);
        return switch (requests.length) {
          1 => dropAfter('id: 1\ndata: a\n\n'),
          2 => dropAfter('id\ndata: b\n\n'),
          _ => streamedResponse(['data: c\n\n']),
        };
      });
      expect(
        await protocol.callTool(
          caller,
          'm.events',
          const {},
          template({'retry_timeout': 1}),
        ),
        ['a', 'b', 'c'],
      );
      expect(requests[1].headers['Last-Event-ID'], '1');
      expect(requests[2].headers.containsKey('Last-Event-ID'), isFalse);
    });

    test('gives up after five reconnects, counting failed ones', () async {
      var count = 0;
      final protocol = protocolFor((request, _) async {
        count++;
        if (count.isEven) throw http.ClientException('refused');
        return dropAfter('data: $count\n\n');
      });
      await expectLater(
        protocol.callTool(
          caller,
          'm.events',
          const {},
          template({'retry_timeout': 1}),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(count, 6);
    });

    test('a clean end of stream never reconnects', () async {
      var count = 0;
      final protocol = protocolFor((request, _) async {
        count++;
        return streamedResponse(['data: 1\n\n']);
      });
      await protocol.callTool(
        caller,
        'm.events',
        const {},
        template({'retry_timeout': 1}),
      );
      expect(count, 1);
    });

    test('the first handshake failing is never retried', () async {
      var count = 0;
      final protocol = protocolFor((request, _) async {
        count++;
        throw http.ClientException('refused');
      });
      await expectLater(
        protocol.callTool(caller, 'm.events', const {}, template()),
        throwsA(isA<http.ClientException>()),
      );
      expect(count, 1);
    });

    test('is off when disabled or when the call sends a body', () async {
      for (final (fields, args) in [
        (<String, Object?>{'reconnect': false}, <String, Object?>{}),
        (
          <String, Object?>{'body_field': 'filter'},
          <String, Object?>{
            'filter': {'level': 'warn'},
          },
        ),
      ]) {
        var count = 0;
        final protocol = protocolFor((request, _) async {
          count++;
          return dropAfter('data: 1\n\n');
        });
        await expectLater(
          protocol.callTool(caller, 'm.events', args, template(fields)),
          throwsA(isA<http.ClientException>()),
        );
        expect(count, 1);
      }
    });

    test('cancelling during the reconnect delay stops reconnecting', () async {
      var count = 0;
      final protocol = protocolFor((request, _) async {
        count++;
        return dropAfter('data: 1\n\n');
      });
      final subscription = protocol
          .callToolStreaming(
            caller,
            'm.events',
            const {},
            template({'retry_timeout': 200}),
          )
          .listen(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel().timeout(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(count, 1);
    });
  });

  group('request', () {
    test('maps arguments, auth and Accept like the HTTP transport', () async {
      late http.BaseRequest seen;
      late String sentBody;
      final protocol = protocolFor((request, body) async {
        seen = request;
        sentBody = await utf8.decodeStream(body);
        return streamedResponse(['data: ok\n\n']);
      });
      await protocol.callTool(
        caller,
        'm.events',
        {
          'stream': 'a b',
          'X-User': 'u1',
          'filter': {'level': 'warn'},
          'limit': 3,
        },
        template({
          'url': 'https://api.example.com/events/{stream}',
          'headers': {'X-Static': 's'},
          'header_fields': ['X-User'],
          'body_field': 'filter',
          'auth': {'auth_type': 'api_key', 'api_key': 'k', 'var_name': 'X-Key'},
        }),
      );
      expect(seen.method, 'POST');
      expect(seen.url.path, '/events/a%20b');
      expect(seen.url.queryParameters, {'limit': '3'});
      expect(seen.headers['Accept'], 'text/event-stream');
      expect(seen.headers['X-Static'], 's');
      expect(seen.headers['X-User'], 'u1');
      expect(seen.headers['X-Key'], 'k');
      expect(seen.headers['Content-Type'], 'application/json');
      expect(jsonDecode(sentBody), {'level': 'warn'});
    });

    test('without a body the request is a GET', () async {
      late http.BaseRequest seen;
      final protocol = protocolFor((request, _) async {
        seen = request;
        return streamedResponse(['data: ok\n\n']);
      });
      await protocol.callTool(caller, 'm.events', const {}, template());
      expect(seen.method, 'GET');
    });
  });

  group('security', () {
    Future<Object?> call(
      MockClientStreamHandler handler,
      JsonMap fields, [
      ToolArguments args = const {},
    ]) => protocolFor(
      handler,
    ).callTool(caller, 'm.events', args, template(fields));

    test('plain HTTP to a remote host is refused', () async {
      await expectLater(
        call((request, _) async => streamedResponse(['data: x\n\n']), {
          'url': 'http://api.example.com/events',
        }),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('an argument cannot move the request onto loopback', () async {
      await expectLater(
        call(
          (request, _) async => streamedResponse(['data: x\n\n']),
          {'url': 'http://{host}:8080/events'},
          {'host': '127.0.0.1'},
        ),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test(
      'redirects are re-validated and drop credentials across origins',
      () async {
        final seen = <http.BaseRequest>[];
        await expectLater(
          call((request, _) async {
            seen.add(request);
            return streamedResponse(
              const [],
              status: 302,
              headers: {'location': 'http://127.0.0.1:9/admin'},
            );
          }, {}),
          throwsA(isA<UtcpSecurityException>()),
        );
        expect(seen, hasLength(1));

        seen.clear();
        final events = await call(
          (request, _) async {
            seen.add(request);
            return seen.length == 1
                ? streamedResponse(
                    const [],
                    status: 307,
                    headers: {'location': 'https://other.example/events'},
                  )
                : streamedResponse(['data: moved\n\n']);
          },
          {
            'auth': {'auth_type': 'basic', 'username': 'u', 'password': 'p'},
          },
        );
        expect(events, ['moved']);
        expect(seen.first.headers['Authorization'], startsWith('Basic '));
        expect(seen.last.headers.containsKey('Authorization'), isFalse);
      },
    );
  });

  group('discovery', () {
    test('a manual without utcp_version is accepted', () async {
      final protocol = protocolFor(
        (request, _) async => streamedResponse([
          jsonEncode({
            'tools': [
              toolWith('t', {
                'call_template_type': 'sse',
                'url': 'https://api.example.com/events',
              }),
            ],
          }),
        ], contentType: 'application/json'),
      );
      final result = await protocol.registerManual(
        caller,
        template({'name': 'm', 'url': manualUrl}),
      );
      expect(result.success, isTrue, reason: '${result.errors}');
      expect(result.manual.tools.single.name, 't');
    });
    test('fetches the manual with headers and auth', () async {
      late http.BaseRequest seen;
      final protocol = protocolFor((request, _) async {
        seen = request;
        return streamedResponse([
          jsonEncode(
            manualJson(
              tools: [
                toolWith('events', {
                  'call_template_type': 'sse',
                  'url': 'https://api.example.com/events',
                }),
              ],
            ),
          ),
        ], contentType: 'application/json');
      });
      final result = await protocol.registerManual(
        caller,
        template({
          'name': 'm',
          'url': manualUrl,
          'headers': {'X-Static': 's'},
          'body_field': 'ignored',
          'auth': {'auth_type': 'api_key', 'api_key': 'k', 'var_name': 'X-Key'},
        }),
      );
      expect(result.success, isTrue, reason: '${result.errors}');
      expect(
        result.manual.tools.single.toolCallTemplate,
        isA<SseCallTemplate>(),
      );
      expect(seen.method, 'GET');
      expect(seen.headers['X-Static'], 's');
      expect(seen.headers['X-Key'], 'k');
    });

    test('failures are returned, including remote loopback tools', () async {
      final protocol = protocolFor(
        (request, _) async => streamedResponse([
          jsonEncode(
            manualJson(
              tools: [
                toolWith('events', {
                  'call_template_type': 'sse',
                  'url': 'http://localhost:8080/events',
                }),
              ],
            ),
          ),
        ], contentType: 'application/json'),
      );
      final result = await protocol.registerManual(
        caller,
        template({'name': 'm', 'url': manualUrl}),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('loopback'));

      final failing = protocolFor(
        (request, _) async =>
            streamedResponse(['down'], status: 503, contentType: 'text/plain'),
      );
      final failed = await failing.registerManual(
        caller,
        template({'name': 'm', 'url': manualUrl}),
      );
      expect(failed.success, isFalse);
      expect(failed.errors.single, contains('503'));
    });
  });

  group('SseCallTemplate', () {
    test('round-trips through JSON with spec defaults', () {
      final parsed = template();
      expect(parsed.eventType, isNull);
      expect(parsed.reconnect, isTrue);
      expect(parsed.retryTimeout, const Duration(seconds: 30));
      expect(parsed.bodyField, isNull);
      final full = template({
        'name': 'm',
        'event_type': 'update',
        'reconnect': false,
        'retry_timeout': 1500,
        'headers': {'A': 'b'},
        'body_field': 'payload',
        'header_fields': ['X-User'],
        'auth': {'auth_type': 'basic', 'username': 'u', 'password': 'p'},
      });
      final again = CallTemplate.fromJson(
        jsonDecode(jsonEncode(full.toJson())) as JsonMap,
      );
      expect(again, isA<SseCallTemplate>());
      expect(again.toJson(), full.toJson());
      expect((again as SseCallTemplate).retryTimeout.inMilliseconds, 1500);
    });

    test('a fractional retry_timeout is kept and round-trips', () {
      final parsed = template({'retry_timeout': 0.5});
      expect(parsed.retryTimeout, const Duration(microseconds: 500));
      expect(parsed.toJson()['retry_timeout'], 0.5);
    });

    test('malformed fields are rejected', () {
      expect(() => template({'retry_timeout': -1}), throwsFormatException);
      expect(() => template({'reconnect': 'yes'}), throwsFormatException);
      expect(() => template({'url': null}), throwsFormatException);
    });
  });
}
