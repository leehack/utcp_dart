import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/src/connect.dart' as generic;
import 'package:utcp_websocket/utcp_websocket.dart';

import '../support/fake_sockets.dart';

void main() {
  late UtcpClient client;
  late List<http.Request> httpRequests;
  late WebSocketCommunicationProtocol protocol;

  setUp(() async {
    httpRequests = [];
    protocol = WebSocketCommunicationProtocol(
      transport: HttpTransport(
        client: MockClient((request) async {
          httpRequests.add(request);
          return http.Response('{}', 500);
        }),
      ),
    );
    client = await UtcpClient.create(protocols: [protocol]);
  });
  tearDown(() => client.close());

  test('plain ws to a remote host is refused before connecting', () async {
    const template = WebSocketCallTemplate(
      name: 'ws',
      url: 'ws://169.254.169.254/socket',
    );
    await expectLater(
      protocol.callTool(client, 'ws.t', const {}, template),
      throwsA(isA<UtcpSecurityException>()),
    );
    await expectLater(
      protocol.callToolStreaming(client, 'ws.t', const {}, template).toList(),
      throwsA(isA<UtcpSecurityException>()),
    );
    final result = await protocol.registerManual(client, template);
    expect(result.success, isFalse);
    expect(result.errors.single, contains('WebSocket URL'));
  });

  test('an insecure OAuth2 token URL is refused before any request', () async {
    const template = WebSocketCallTemplate(
      url: 'wss://tools.example.com/ws',
      auth: OAuth2Auth(
        tokenUrl: 'http://169.254.169.254/token',
        clientId: 'id',
        clientSecret: 'secret',
      ),
    );
    await expectLater(
      protocol.callTool(client, 't', const {}, template),
      throwsA(isA<UtcpSecurityException>()),
    );
    expect(httpRequests, isEmpty);
  });

  test('a header field cannot smuggle CR or LF into the handshake', () async {
    const template = WebSocketCallTemplate(
      url: 'wss://tools.example.com/ws',
      headerFields: ['X-User'],
    );
    await expectLater(
      protocol.callTool(client, 't', {'X-User': 'a\r\nHost: evil'}, template),
      throwsA(isA<UtcpSecurityException>()),
    );
  });

  test('rejects templates of another type', () async {
    await expectLater(
      protocol.callTool(
        client,
        't',
        const {},
        const HttpCallTemplate(url: 'https://x'),
      ),
      throwsArgumentError,
    );
  });

  test('close is final', () async {
    const template = WebSocketCallTemplate(
      name: 'ws',
      url: 'ws://localhost:1/ws',
    );
    await protocol.close();
    await expectLater(
      protocol.callTool(client, 'ws.t', const {}, template),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
    final result = await protocol.registerManual(client, template);
    expect(result.errors.single, contains('closed'));
  });

  test('deregistering a manual without a connection is a no-op', () async {
    await protocol.deregisterManual(
      client,
      const WebSocketCallTemplate(url: 'wss://x/ws'),
    );
  });

  test('without dart:io, handshake headers are refused', () async {
    await expectLater(
      generic.connectWebSocket(
        Uri.parse('wss://tools.example.com/ws'),
        headers: {'Authorization': 'Bearer secret'},
        protocol: null,
        pingInterval: null,
        timeout: const Duration(seconds: 1),
        cancel: const Stream.empty(),
      ),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Authorization'), isNot(contains('secret'))),
        ),
      ),
    );
  });

  group('with in-memory sockets', () {
    late FakeSockets sockets;
    late WebSocketCommunicationProtocol fake;

    void withSockets(FakeSockets s) {
      sockets = s;
      fake = WebSocketCommunicationProtocol(connector: s.call);
      addTearDown(fake.close);
    }

    String manualJson(String url) => jsonEncode({
      'utcp_version': '1.0.1',
      'manual_version': '1.0.0',
      'tools': [
        {
          'name': 't',
          'tool_call_template': {
            'call_template_type': 'websocket',
            'url': url,
            'header_fields': ['X-Req'],
          },
        },
      ],
    });

    test('a frame that arrived before a call never answers it', () async {
      var n = 0;
      withSockets(
        FakeSockets((server, _) {
          n++;
          server
            ..sendText('answer-$n')
            ..sendText('trailer-$n');
        }),
      );
      const template = WebSocketCallTemplate(url: 'wss://tools.example.com/ws');
      expect(await fake.callTool(client, 't', const {}, template), 'answer-1');
      await pumpEventQueue();
      expect(await fake.callTool(client, 't', const {}, template), 'answer-2');
      expect(sockets.open, 1);
    });

    test('with two frames per request, each call gets its own', () async {
      withSockets(
        FakeSockets((server, text) {
          final name = (jsonDecode(text) as Map<String, Object?>)['q'];
          if (name.toString().startsWith('stream')) {
            for (var i = 0; i < 2; i++) {
              server.sendText(
                jsonEncode({'type': 'tool_response', 'result': '$name-$i'}),
              );
            }
            server
              ..sendText(jsonEncode({'type': 'stream_end'}))
              ..sendText('after-$name');
          } else {
            server
              ..sendText('$name-0')
              ..sendText('$name-1');
          }
        }),
      );
      const template = WebSocketCallTemplate(url: 'wss://tools.example.com/ws');
      Future<Object?> call(String q) =>
          fake.callTool(client, 't', {'q': q}, template);
      Future<List<Object?>> stream(String q) =>
          fake.callToolStreaming(client, 't', {'q': q}, template).toList();

      expect(await call('one'), 'one-0');
      await pumpEventQueue();
      expect(await call('two'), 'two-0');
      await pumpEventQueue();
      expect(await stream('stream1'), ['stream1-0', 'stream1-1']);
      await pumpEventQueue();
      expect(await stream('stream2'), ['stream2-0', 'stream2-1']);
      await pumpEventQueue();
      expect(await call('three'), 'three-0');
      expect(sockets.handshakes, hasLength(1));
    });

    test(
      'a frame that arrives after the next call was sent answers it',
      () async {
        // The limit of frames without correlation ids: this server sends its
        // second frame for a request only once the next request arrives.
        String? pending;
        withSockets(
          FakeSockets((server, text) {
            final late = pending;
            if (late != null) server.sendText(late);
            server.sendText('answer:$text');
            pending = 'late:$text';
          }),
        );
        const template = WebSocketCallTemplate(
          url: 'wss://tools.example.com/ws',
          message: 'UTCP_ARG_q_UTCP_ARG',
        );
        expect(
          await fake.callTool(client, 't', {'q': 1}, template),
          'answer:1',
        );
        expect(await fake.callTool(client, 't', {'q': 2}, template), 'late:1');
      },
    );

    test('a call waiting for a busy connection times out', () async {
      withSockets(
        FakeSockets(
          (server, _) => server.sendText(
            jsonEncode({'type': 'tool_response', 'result': 1}),
          ),
        ),
      );
      const url = 'wss://tools.example.com/ws';
      final holder = StreamIterator(
        fake.callToolStreaming(
          client,
          't',
          const {},
          const WebSocketCallTemplate(url: url),
        ),
      );
      expect(await holder.moveNext(), isTrue);
      await expectLater(
        fake.callTool(
          client,
          't',
          const {},
          const WebSocketCallTemplate(url: url, timeout: Duration(seconds: 1)),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('Waiting for the WebSocket connection'),
          ),
        ),
      );
      await holder.cancel();
    });

    test('deregistering aborts a connection in progress', () async {
      final gate = Completer<void>();
      var cancelled = false;
      final inner = FakeSockets(
        (server, _) =>
            server.sendText(manualJson('wss://tools.example.com/ws')),
      );
      var gated = true;
      fake = WebSocketCommunicationProtocol(
        connector: (uri, headers, template, cancel) async {
          if (gated) {
            cancel.listen((_) => cancelled = true);
            await gate.future;
          }
          return inner(uri, headers, template, cancel);
        },
      );
      addTearDown(fake.close);
      const manual = WebSocketCallTemplate(
        name: 'ws',
        url: 'wss://tools.example.com/ws',
      );
      final registering = fake.registerManual(client, manual);
      await pumpEventQueue();
      final deregistering = fake.deregisterManual(client, manual);
      expect(cancelled, isTrue);
      // A connector that ignores the cancel is closed once it completes.
      gate.complete();
      await deregistering;
      final result = await registering;
      expect(result.success, isFalse);
      expect(result.errors.single, contains('cancelled'));
      await pumpEventQueue();
      expect(inner.handshakes, hasLength(1));
      expect(inner.open, 0);

      gated = false;
      expect((await fake.registerManual(client, manual)).success, isTrue);
      expect(inner.open, 1);
    });

    test('header field calls close their connection afterwards', () async {
      withSockets(
        FakeSockets((server, text) {
          server.sendText(
            text == utcpDiscoveryMessage
                ? manualJson('wss://tools.example.com/ws')
                : 'ok',
          );
        }),
      );
      final utcp = await UtcpClient.create(protocols: [fake]);
      addTearDown(utcp.close);
      final result = await utcp.registerManual(
        const WebSocketCallTemplate(
          name: 'ws',
          url: 'wss://tools.example.com/ws',
        ),
      );
      expect(result.success, isTrue, reason: '${result.errors}');
      for (var i = 0; i < 20; i++) {
        expect(await utcp.callTool('ws.t', {'X-Req': 'id-$i'}), 'ok');
        await pumpEventQueue();
        expect(sockets.open, 1, reason: 'only the manual connection');
      }
      expect(sockets.handshakes.skip(1).map((h) => h.headers['X-Req']), [
        for (var i = 0; i < 20; i++) 'id-$i',
      ]);
      await utcp.deregisterManual('ws');
      await pumpEventQueue();
      expect(sockets.open, 0);
    });

    test('close closes connections in use and refuses new calls', () async {
      withSockets(FakeSockets());
      const template = WebSocketCallTemplate(
        url: 'wss://tools.example.com/ws',
        headerFields: ['X-Req'],
      );
      final failures = [
        expectLater(
          fake.callTool(client, 't', const {}, template),
          throwsA(isA<UtcpException>()),
        ),
        expectLater(
          fake.callTool(client, 't', {'X-Req': '1'}, template),
          throwsA(isA<UtcpException>()),
        ),
      ];
      await pumpEventQueue();
      expect(sockets.open, 2);
      await fake.close();
      await Future.wait(failures);
      await pumpEventQueue();
      expect(sockets.open, 0);
      await expectLater(
        fake.callTool(client, 't', const {}, template),
        throwsA(isA<UtcpException>()),
      );
    });

    test('close aborts handshakes in progress', () async {
      final gate = Completer<void>();
      var cancelled = false;
      final inner = FakeSockets();
      fake = WebSocketCommunicationProtocol(
        connector: (uri, headers, template, cancel) async {
          cancel.listen((_) => cancelled = true);
          await gate.future;
          return inner(uri, headers, template, cancel);
        },
      );
      const template = WebSocketCallTemplate(url: 'wss://tools.example.com/ws');
      final failed = expectLater(
        fake.callTool(client, 't', const {}, template),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      await pumpEventQueue();
      final closing = fake.close();
      expect(cancelled, isTrue);
      // A handshake that ignores the cancel is closed once it completes.
      gate.complete();
      await closing;
      await failed;
      await pumpEventQueue();
      expect(inner.handshakes, hasLength(1));
      expect(inner.open, 0);
    });

    test('a remote manual may not point tools at loopback', () async {
      for (final url in ['ws://127.0.0.1:9/admin', 'wss://localhost/x']) {
        withSockets(
          FakeSockets((server, _) => server.sendText(manualJson(url))),
        );
        final result = await fake.registerManual(
          client,
          const WebSocketCallTemplate(
            name: 'ws',
            url: 'wss://tools.example.com/ws',
          ),
        );
        expect(result.success, isFalse, reason: url);
        expect(result.errors.single, contains('loopback'));
        await pumpEventQueue();
        expect(sockets.open, 0, reason: 'the failed discovery closes');
      }
    });

    test('errors and logs name the URL without its query', () async {
      final records = <String>[];
      final logs = Logger.root.onRecord.listen((r) => records.add(r.message));
      addTearDown(logs.cancel);
      withSockets(FakeSockets());
      final result = await fake.registerManual(
        client,
        const WebSocketCallTemplate(
          name: 'ws',
          url: 'wss://tools.example.com/ws?token=s3cret',
          timeout: Duration(seconds: 1),
        ),
      );
      expect(result.errors.single, contains('wss://tools.example.com/ws'));
      expect(records, isNotEmpty);
      expect([
        ...result.errors,
        ...records,
      ], everyElement(isNot(contains('s3cret'))));
    });
  });

  test('an HTTP manual from a remote origin may not declare loopback WebSocket '
      'tools', () async {
    final utcp = await UtcpClient.create(
      protocols: [
        HttpCommunicationProtocol(
          transport: HttpTransport(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'utcp_version': '1.0.1',
                  'manual_version': '1.0.0',
                  'tools': [
                    {
                      'name': 'cdp',
                      'tool_call_template': {
                        'call_template_type': 'websocket',
                        'url': 'ws://127.0.0.1:9222/devtools/browser',
                      },
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
        ),
        protocol,
      ],
    );
    addTearDown(utcp.close);
    final result = await utcp.registerManual(
      CallTemplate.fromJson({
        'name': 'evil',
        'call_template_type': 'http',
        'url': 'https://evil.example/utcp',
        'http_method': 'GET',
        'allowed_communication_protocols': ['http', 'websocket'],
      }),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, contains('loopback'));
    expect(await utcp.searchTools(''), isEmpty);
  });
}
