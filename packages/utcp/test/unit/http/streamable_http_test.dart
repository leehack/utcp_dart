import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  StreamableHttpCallTemplate template([JsonMap fields = const {}]) =>
      StreamableHttpCallTemplate.fromJson({
        'call_template_type': 'streamable_http',
        'url': 'https://api.example.com/export',
        ...fields,
      });

  StreamableHttpCommunicationProtocol protocolFor(
    MockClientStreamHandler handler, {
    int maxLineChars = 16 * 1024 * 1024,
  }) => StreamableHttpCommunicationProtocol(
    transport: mockTransport(handler),
    maxLineChars: maxLineChars,
  );

  Stream<Object?> stream(
    List<Object> parts,
    String contentType, {
    JsonMap fields = const {},
    int maxLineChars = 16 * 1024 * 1024,
  }) => protocolFor(
    (request, _) async => streamedResponse(parts, contentType: contentType),
    maxLineChars: maxLineChars,
  ).callToolStreaming(caller, 'm.export', const {}, template(fields));

  group('NDJSON', () {
    test('yields one value per line across chunk boundaries', () async {
      expect(
        await stream([
          '{"a":1}\n{"b"',
          ':2}\r\n\n  \n',
          'not json\n',
          utf8.encode('"한').sublist(0, 2),
          utf8.encode('"한"\n').sublist(2),
          '[3]',
        ], 'application/x-ndjson; charset=utf-8').toList(),
        [
          {'a': 1},
          {'b': 2},
          'not json',
          '한',
          [3],
        ],
      );
    });

    test('a line over the limit is an error', () async {
      expect(
        stream(
          ['{"a":"${'x' * 40}', '"}\n'],
          'application/x-ndjson',
          maxLineChars: 32,
        ).toList(),
        throwsA(isA<UtcpException>()),
      );
      expect(
        stream(
          ['{"a":"${'x' * 40}"}\n'],
          'application/x-ndjson',
          maxLineChars: 32,
        ).toList(),
        throwsA(isA<UtcpException>()),
      );
    });

    test('callTool returns the values as a list', () async {
      final protocol = protocolFor(
        (request, _) async =>
            streamedResponse(['1\n2\n'], contentType: 'application/x-ndjson'),
      );
      expect(
        await protocol.callTool(caller, 'm.export', const {}, template()),
        [1, 2],
      );
    });
  });

  group('JSON', () {
    test('the whole body is one value', () async {
      expect(
        await stream(['{"items":', '[1,2]}'], 'application/json').toList(),
        [
          {
            'items': [1, 2],
          },
        ],
      );
    });

    test(
      'an invalid body is yielded as raw bytes, an empty one not at all',
      () async {
        final chunks = await stream(['{oops'], 'application/json').toList();
        expect(chunks.single, isA<Uint8List>());
        expect(utf8.decode(chunks.single! as List<int>), '{oops');
        expect(await stream(const [], 'application/json').toList(), isEmpty);
      },
    );
  });

  group('binary', () {
    test(
      'chunks are at most chunk_size bytes and yielded as they arrive',
      () async {
        final chunks = await stream(
          [List.filled(10, 1), List.filled(3, 2)],
          'application/octet-stream',
          fields: {'chunk_size': 4},
        ).toList();
        expect(
          [for (final c in chunks) (c! as Uint8List).length],
          [4, 4, 2, 3],
        );
      },
    );

    test('unknown content types are treated as binary', () async {
      final chunks = await stream(['plain'], 'text/plain').toList();
      expect(chunks.single, isA<Uint8List>());
    });

    test('callTool joins the bytes', () async {
      final protocol = protocolFor(
        (request, _) async => streamedResponse([
          'ab',
          'cd',
        ], contentType: 'application/octet-stream'),
      );
      final result = await protocol.callTool(
        caller,
        'm.export',
        const {},
        template({'chunk_size': 1}),
      );
      expect(result, isA<Uint8List>());
      expect(utf8.decode(result! as List<int>), 'abcd');
    });
  });

  group('lifecycle', () {
    test('chunks arrive before the response ends', () async {
      final body = ControlledBody();
      final protocol = protocolFor(
        (request, _) async =>
            body.response(contentType: 'application/x-ndjson'),
      );
      final received = Completer<Object?>();
      final done = protocol
          .callToolStreaming(caller, 'm.export', const {}, template())
          .listen((chunk) {
            if (!received.isCompleted) received.complete(chunk);
          })
          .asFuture<void>();
      body.add('{"n":1}\n');
      expect(await received.future, {'n': 1});
      await body.close();
      await done;
    });

    test('cancelling closes the response at once', () async {
      final body = ControlledBody();
      final protocol = protocolFor(
        (request, _) async =>
            body.response(contentType: 'application/x-ndjson'),
      );
      final subscription = protocol
          .callToolStreaming(caller, 'm.export', const {}, template())
          .listen(null);
      body.add('1\n');
      await pumpEventQueue();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await body.cancelled.future.timeout(const Duration(seconds: 1));
    });

    test('the timeout covers reading the stream', () async {
      final body = ControlledBody();
      final protocol = protocolFor(
        (request, _) async =>
            body.response(contentType: 'application/x-ndjson'),
      );
      body.add('1\n');
      final chunks = <Object?>[];
      await expectLater(
        protocol
            .callToolStreaming(
              caller,
              'm.export',
              const {},
              template({'timeout': 50}),
            )
            .map(chunks.add)
            .drain<void>(),
        throwsA(
          isA<UtcpException>().having((e) => e.message, 'm', contains('Timed')),
        ),
      );
      expect(chunks, [1]);
      await body.cancelled.future.timeout(const Duration(seconds: 1));
    });

    test('4xx and 5xx fail with the status and server reason', () async {
      for (final status in [400, 403, 500]) {
        final protocol = protocolFor(
          (request, _) async => streamedResponse(
            ['{"message":"bad $status"}'],
            status: status,
            contentType: 'application/json',
          ),
        );
        await expectLater(
          protocol.callTool(caller, 'm.export', const {}, template()),
          throwsA(
            isA<UtcpHttpException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.message, 'message', contains('bad')),
          ),
        );
      }
    });
  });

  group('request', () {
    test('maps arguments and uses content_type for the body', () async {
      late http.BaseRequest seen;
      late String sentBody;
      final protocol = protocolFor((request, body) async {
        seen = request;
        sentBody = await utf8.decodeStream(body);
        return streamedResponse(['ok'], contentType: 'text/plain');
      });
      await protocol.callTool(
        caller,
        'm.export',
        {'table': 'users', 'X-Trace': 't', 'data': 'raw', 'page': 2},
        template({
          'url': 'https://api.example.com/export/{table}',
          'http_method': 'POST',
          'body_field': 'data',
          'header_fields': ['X-Trace'],
          'auth': {'auth_type': 'basic', 'username': 'u', 'password': 'p'},
        }),
      );
      expect(seen.method, 'POST');
      expect(seen.url.path, '/export/users');
      expect(seen.url.queryParameters, {'page': '2'});
      expect(seen.headers['X-Trace'], 't');
      expect(seen.headers['Content-Type'], 'application/octet-stream');
      expect(seen.headers['Authorization'], startsWith('Basic '));
      expect(sentBody, 'raw');
    });
  });

  group('security', () {
    test(
      'plain HTTP to a remote host and argument-chosen loopback are refused',
      () async {
        final protocol = protocolFor(
          (request, _) async =>
              streamedResponse(['x'], contentType: 'text/plain'),
        );
        await expectLater(
          protocol.callTool(
            caller,
            'm.export',
            const {},
            template({'url': 'http://api.example.com/export'}),
          ),
          throwsA(isA<UtcpSecurityException>()),
        );
        await expectLater(
          protocol.callTool(caller, 'm.export', {
            'url': 'http://localhost:9/admin',
          }, template({'url': '{url}'})),
          throwsA(isA<UtcpSecurityException>()),
        );
      },
    );

    test('a redirect from a remote origin into loopback is refused', () async {
      final protocol = protocolFor(
        (request, _) async => streamedResponse(
          const [],
          status: 301,
          headers: {'location': 'http://localhost:9/admin'},
        ),
      );
      await expectLater(
        protocol.callTool(caller, 'm.export', const {}, template()),
        throwsA(isA<UtcpSecurityException>()),
      );
    });
  });

  group('discovery', () {
    test(
      'uses the template method and rejects remote loopback tools',
      () async {
        final methods = <String>[];
        final protocol = protocolFor((request, _) async {
          methods.add(request.method);
          return streamedResponse([
            jsonEncode(
              manualJson(
                tools: [
                  toolWith('export', {
                    'call_template_type': 'streamable_http',
                    'url': methods.length == 1
                        ? 'https://api.example.com/export'
                        : 'http://127.0.0.1:9/export',
                  }),
                ],
              ),
            ),
          ], contentType: 'application/json');
        });
        final ok = await protocol.registerManual(
          caller,
          template({'name': 'm', 'url': manualUrl, 'http_method': 'POST'}),
        );
        expect(ok.success, isTrue, reason: '${ok.errors}');
        expect(
          ok.manual.tools.single.toolCallTemplate,
          isA<StreamableHttpCallTemplate>(),
        );
        final rejected = await protocol.registerManual(
          caller,
          template({'name': 'm', 'url': manualUrl}),
        );
        expect(rejected.success, isFalse);
        expect(methods, ['POST', 'GET']);
      },
    );
  });

  group('StreamableHttpCallTemplate', () {
    test('round-trips through JSON with spec defaults', () {
      final parsed = template();
      expect(parsed.httpMethod, HttpMethod.get);
      expect(parsed.contentType, 'application/octet-stream');
      expect(parsed.chunkSize, 4096);
      expect(parsed.timeout, const Duration(seconds: 60));
      final full = template({
        'name': 'm',
        'http_method': 'POST',
        'content_type': 'application/json',
        'chunk_size': 10,
        'timeout': 1000,
        'headers': {'A': 'b'},
        'body_field': 'payload',
        'header_fields': ['X'],
      });
      final again = CallTemplate.fromJson(
        jsonDecode(jsonEncode(full.toJson())) as JsonMap,
      );
      expect(again, isA<StreamableHttpCallTemplate>());
      expect(again.toJson(), full.toJson());
    });

    test('malformed fields are rejected', () {
      for (final fields in [
        {'http_method': 'PUT'},
        {'chunk_size': 0},
        {'timeout': 0},
        {'timeout': -5},
        {'chunk_size': 'big'},
      ]) {
        expect(
          () => template(fields),
          throwsFormatException,
          reason: '$fields',
        );
      }
    });
  });
}
