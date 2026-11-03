@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/local_http_server.dart';
import '../support/raw_http_server.dart';
import '../support/streaming.dart';

void main() {
  late UtcpClient caller;
  setUpAll(() async => caller = await bareClient());
  tearDownAll(() => caller.close());

  /// Sends headers for a streamed response. Without turning off output
  /// buffering, HttpServer holds small writes back despite `flush`.
  void startStream(HttpRequest request, ContentType contentType) =>
      request.response
        ..bufferOutput = false
        ..headers.contentType = contentType;

  /// Writes [text] and flushes it onto the socket.
  Future<void> send(HttpRequest request, String text) async {
    request.response.write(text);
    await request.response.flush();
  }

  /// Listens until [first] arrives, then cancels once the stream has gone
  /// quiet, so the cancel does not land while the producer sits at a
  /// `yield`.
  Future<void> cancelWhileQuiet(Stream<Object?> stream, Object? first) async {
    final received = Completer<Object?>();
    final subscription = stream.listen((event) {
      if (!received.isCompleted) received.complete(event);
    });
    expect(await received.future.timeout(const Duration(seconds: 2)), first);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel().timeout(const Duration(seconds: 2));
  }

  final eventStream = ContentType('text', 'event-stream');
  final ndjson = ContentType('application', 'x-ndjson');

  group('sse', () {
    late LocalHttpServer server;
    final protocol = SseCommunicationProtocol();
    tearDown(() => server.close());
    tearDownAll(protocol.close);

    SseCallTemplate template([JsonMap fields = const {}]) =>
        SseCallTemplate.fromJson({
          'call_template_type': 'sse',
          'url': '${server.baseUrl}/events',
          ...fields,
        });

    test('events arrive one by one while the server keeps writing', () async {
      final firstSeen = Completer<void>();
      server = await LocalHttpServer.start((request, _) async {
        startStream(request, eventStream);
        await send(request, 'event: progress\r\ndata: {"pct"');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await send(request, ': 50}\r\n\r\n');
        // Held back until the client has yielded the first event.
        await firstSeen.future;
        await send(request, 'event: progress\ndata: {"pct": 100}\n\n');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await send(request, 'event: done\ndata: ok\n\n');
      });
      final received = <Object?>[];
      await for (final event in protocol.callToolStreaming(
        caller,
        'm.progress',
        const {},
        template({'event_type': 'progress'}),
      )) {
        received.add(event);
        if (!firstSeen.isCompleted) firstSeen.complete();
      }
      expect(received, [
        {'pct': 50},
        {'pct': 100},
      ]);
    });

    test('an HTTP error while opening fails the call', () async {
      server = await LocalHttpServer.start(
        (request, _) =>
            request.response.json({'error': 'forbidden'}, status: 403),
      );
      await expectLater(
        protocol.callTool(caller, 'm.events', const {}, template()),
        throwsA(
          isA<UtcpHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', contains('forbidden')),
        ),
      );
    });

    test('a shared transport keeps working after cancelled streams', () async {
      server = await LocalHttpServer.start((request, _) async {
        startStream(request, eventStream);
        await send(request, 'data: 1\n\n');
      });
      for (var i = 0; i < 3; i++) {
        expect(
          await protocol
              .callToolStreaming(caller, 'm.e', const {}, template())
              .first,
          1,
        );
      }
      expect(await protocol.callTool(caller, 'm.e', const {}, template()), [1]);
    });
  });

  group('sse over a raw socket', () {
    late RawHttpServer server;
    final protocol = SseCommunicationProtocol();
    tearDown(() => server.close());
    tearDownAll(protocol.close);

    test(
      'cancelling closes the connection while the stream is quiet',
      () async {
        final gone = Completer<void>();
        server = await RawHttpServer.start((exchange) async {
          await exchange.respond('text/event-stream');
          await exchange.write('data: first\n\n');
          await exchange.clientGone;
          gone.complete();
        });
        await cancelWhileQuiet(
          protocol.callToolStreaming(
            caller,
            'm.events',
            const {},
            SseCallTemplate(url: '${server.baseUrl}/events'),
          ),
          'first',
        );
        await gone.future.timeout(const Duration(seconds: 2));
      },
    );

    test('a dropped connection resumes with Last-Event-ID', () async {
      final lastEventIds = <String?>[];
      server = await RawHttpServer.start((exchange) async {
        final id = exchange.header('Last-Event-ID');
        lastEventIds.add(id);
        if (id == null) {
          // Fewer bytes than announced, then a hang-up: a lost connection.
          await exchange.respond('text/event-stream', contentLength: 1000);
          await exchange.write('retry: 10\nid: 1\ndata: a\n\n');
        } else {
          await exchange.respond('text/event-stream');
          await exchange.write('id: 2\ndata: b\n\n');
        }
        exchange.socket.destroy();
      });
      final events = await protocol.callTool(
        caller,
        'm.events',
        const {},
        SseCallTemplate(url: '${server.baseUrl}/events'),
      );
      expect(events, ['a', 'b']);
      expect(lastEventIds, [null, '1']);
    });
  });

  group('streamable_http', () {
    late LocalHttpServer server;
    final protocol = StreamableHttpCommunicationProtocol();
    tearDown(() => server.close());
    tearDownAll(protocol.close);

    StreamableHttpCallTemplate template([JsonMap fields = const {}]) =>
        StreamableHttpCallTemplate.fromJson({
          'call_template_type': 'streamable_http',
          'url': '${server.baseUrl}/export',
          ...fields,
        });

    test('NDJSON lines arrive while the server keeps writing', () async {
      final firstSeen = Completer<void>();
      server = await LocalHttpServer.start((request, _) async {
        startStream(request, ndjson);
        await send(request, '{"row":');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await send(request, '1}\n');
        await firstSeen.future;
        await send(request, '{"row":2}\n{"row":3}');
      });
      final rows = <Object?>[];
      await for (final row in protocol.callToolStreaming(
        caller,
        'm.export',
        const {},
        template(),
      )) {
        rows.add(row);
        if (!firstSeen.isCompleted) firstSeen.complete();
      }
      expect(rows, [
        {'row': 1},
        {'row': 2},
        {'row': 3},
      ]);
    });

    test('binary responses are chunked and joined by callTool', () async {
      server = await LocalHttpServer.start((request, body) async {
        startStream(request, ContentType.binary);
        for (final part in ['hello ', 'stream', 'ing ', body]) {
          await send(request, part);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final fields = {
        'http_method': 'POST',
        'body_field': 'payload',
        'chunk_size': 4,
      };
      final chunks = await protocol.callToolStreaming(caller, 'm.download', {
        'payload': 'world',
      }, template(fields)).toList();
      expect(chunks.every((c) => c is Uint8List && c.length <= 4), isTrue);
      expect(
        utf8.decode([for (final c in chunks) ...c! as Uint8List]),
        'hello streaming world',
      );
      final joined = await protocol.callTool(caller, 'm.download', {
        'payload': '!',
      }, template(fields));
      expect(utf8.decode(joined! as Uint8List), 'hello streaming !');
    });

    test('the timeout covers a stalled stream', () async {
      final release = Completer<void>();
      addTearDown(release.complete);
      server = await LocalHttpServer.start((request, _) async {
        startStream(request, ndjson);
        await send(request, '1\n');
        await release.future;
      });
      await expectLater(
        protocol.callTool(
          caller,
          'm.export',
          const {},
          template({'timeout': 100}),
        ),
        throwsA(
          isA<UtcpException>().having((e) => e.message, 'm', contains('Timed')),
        ),
      );
    });

    test('a 5xx while opening fails the call', () async {
      server = await LocalHttpServer.start(
        (request, _) =>
            request.response.json({'message': 'exploded'}, status: 502),
      );
      await expectLater(
        protocol.callTool(caller, 'm.export', const {}, template()),
        throwsA(
          isA<UtcpHttpException>()
              .having((e) => e.statusCode, 'status', 502)
              .having((e) => e.message, 'message', contains('exploded')),
        ),
      );
    });
  });

  test('streamable_http: cancelling closes the connection', () async {
    final gone = Completer<void>();
    final server = await RawHttpServer.start((exchange) async {
      await exchange.respond('application/x-ndjson');
      await exchange.write('1\n');
      await exchange.clientGone;
      gone.complete();
    });
    addTearDown(server.close);
    final protocol = StreamableHttpCommunicationProtocol();
    addTearDown(protocol.close);
    await cancelWhileQuiet(
      protocol.callToolStreaming(
        caller,
        'm.export',
        const {},
        StreamableHttpCallTemplate(url: '${server.baseUrl}/export'),
      ),
      1,
    );
    await gone.future.timeout(const Duration(seconds: 2));
  });
}
