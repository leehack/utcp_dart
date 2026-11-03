@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/src/connect_io.dart';
import 'package:utcp_websocket/src/websocket_connection.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

import '../support/websocket_server.dart';

void main() {
  late UtcpClient client;
  late WebSocketCommunicationProtocol protocol;

  setUp(() async {
    protocol = WebSocketCommunicationProtocol();
    client = await UtcpClient.create(protocols: [protocol]);
  });
  tearDown(() => client.close());

  Future<WebSocketTestServer> serve(
    void Function(WebSocket socket, Stream<Object?> frames) onConnect, {
    Future<bool> Function(HttpRequest request)? onRequest,
    String? Function(List<String> protocols)? protocolSelector,
  }) async {
    final server = await WebSocketTestServer.start(
      onConnect,
      onRequest: onRequest,
      protocolSelector: protocolSelector,
    );
    addTearDown(server.close);
    return server;
  }

  /// Answers every text frame with `echo:<frame>`.
  Future<WebSocketTestServer> echo({Duration delay = Duration.zero}) => serve(
    (socket, frames) => frames.listen((frame) async {
      await Future<void>.delayed(delay);
      socket.add('echo:$frame');
    }),
  );

  WebSocketCallTemplate at(
    WebSocketTestServer server, {
    Object? message,
    WebSocketResponseFormat? responseFormat,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> headers = const {},
    List<String> headerFields = const [],
    Auth? auth,
    String? subprotocol,
  }) => WebSocketCallTemplate(
    name: 'ws',
    url: server.url,
    message: message,
    responseFormat: responseFormat,
    timeout: timeout,
    headers: headers,
    headerFields: headerFields,
    auth: auth,
    protocol: subprotocol,
  );

  group('tool calls', () {
    test('send the arguments as JSON and return the next frame', () async {
      final server = await echo();
      expect(
        await protocol.callTool(client, 't', {'a': 1}, at(server)),
        'echo:{"a":1}',
      );
    });

    test('use string and object message templates', () async {
      final server = await echo();
      expect(
        await protocol.callTool(
          client,
          't',
          {'cmd': 'SET', 'v': 2},
          at(
            server,
            message: 'CMD:UTCP_ARG_cmd_UTCP_ARG;V:UTCP_ARG_v_UTCP_ARG',
          ),
        ),
        'echo:CMD:SET;V:2',
      );
      expect(
        await protocol.callTool(
          client,
          't',
          {'cmd': 'GO'},
          at(
            server,
            message: {'type': 'request', 'cmd': 'UTCP_ARG_cmd_UTCP_ARG'},
          ),
        ),
        'echo:{"type":"request","cmd":"GO"}',
      );
    });

    test('parse JSON responses when asked, and return binary frames', () async {
      final server = await serve(
        (socket, frames) => frames.listen((frame) {
          socket.add(frame == '{"bin":true}' ? [1, 2, 3] : '{"ok":true}');
        }),
      );
      expect(
        await protocol.callTool(
          client,
          't',
          const {},
          at(server, responseFormat: WebSocketResponseFormat.json),
        ),
        {'ok': true},
      );
      final binary = await protocol.callTool(client, 't', {
        'bin': true,
      }, at(server));
      expect(binary, isA<Uint8List>());
      expect(binary, [1, 2, 3]);
    });

    test('reuse one connection and serialize concurrent calls', () async {
      final server = await echo(delay: const Duration(milliseconds: 30));
      final template = at(server);
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          protocol.callTool(client, 't', {'i': i}, template),
      ]);
      expect(results, [for (var i = 0; i < 5; i++) 'echo:{"i":$i}']);
      expect(server.sockets, hasLength(1));
    });

    test(
      'time out, close the connection and reconnect for the next call',
      () async {
        var first = true;
        final server = await serve(
          (socket, frames) => frames.listen((frame) {
            if (first) {
              first = false;
              return;
            }
            socket.add('late or not, here I am');
          }),
        );
        final template = at(server, timeout: const Duration(seconds: 1));
        final closed = server.closed.stream.first;
        await expectLater(
          protocol.callTool(client, 't', const {}, template),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
        await closed.timeout(const Duration(seconds: 2));
        expect(
          await protocol.callTool(client, 't', const {}, template),
          'late or not, here I am',
        );
        expect(server.sockets, hasLength(2));
      },
    );

    test('fail when the server disconnects before answering', () async {
      final server = await serve(
        (socket, frames) => frames.listen((_) => socket.close()),
      );
      await expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('reconnect after the server closes an idle connection', () async {
      final server = await echo();
      final template = at(server);
      await protocol.callTool(client, 't', const {}, template);
      final closed = server.closed.stream.first;
      await server.sockets.single.close();
      await closed;
      expect(
        await protocol.callTool(client, 't', {'b': 2}, template),
        'echo:{"b":2}',
      );
      expect(server.sockets, hasLength(2));
    });
  });

  group('handshake', () {
    test('sends static headers, header fields and header auth', () async {
      final server = await echo();
      final result = await protocol.callTool(
        client,
        't',
        {'X-User': 'u1', 'q': 'x'},
        at(
          server,
          headers: {'X-Static': 's'},
          headerFields: ['X-User'],
          auth: const ApiKeyAuth(apiKey: 'k1', varName: 'X-Api-Key'),
        ),
      );
      expect(
        result,
        'echo:{"q":"x"}',
        reason: 'header fields leave the message',
      );
      final headers = server.requests.single.headers;
      expect(headers.value('X-Static'), 's');
      expect(headers.value('X-User'), 'u1');
      expect(headers.value('X-Api-Key'), 'k1');
    });

    test('a call with header fields closes its own connection', () async {
      final server = await echo();
      final template = at(server, headerFields: ['X-User']);
      final closed = server.closed.stream.take(3).drain<void>();
      for (final user in ['a', 'b', 'a']) {
        expect(
          await protocol.callTool(client, 't', {'X-User': user}, template),
          'echo:{}',
        );
      }
      expect(server.requests.map((r) => r.headers.value('X-User')), [
        'a',
        'b',
        'a',
      ]);
      await closed.timeout(const Duration(seconds: 2));
    });

    test('basic auth and query API keys', () async {
      final server = await echo();
      await protocol.callTool(
        client,
        't',
        const {},
        at(
          server,
          auth: const BasicAuth(username: 'u', password: 'p'),
        ),
      );
      await protocol.callTool(
        client,
        't',
        const {},
        at(
          server,
          auth: const ApiKeyAuth(
            apiKey: 'qk',
            varName: 'token',
            location: ApiKeyLocation.query,
          ),
        ),
      );
      expect(
        server.requests[0].headers.value('authorization'),
        'Basic ${base64Encode(utf8.encode('u:p'))}',
      );
      expect(server.requests[1].uri.queryParameters['token'], 'qk');
    });

    test(
      'OAuth2 client credentials are fetched once and sent as a bearer token',
      () async {
        var tokenRequests = 0;
        final tokens = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => tokens.close(force: true));
        tokens.listen((request) async {
          tokenRequests++;
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'access_token': 'tok', 'expires_in': 60}));
          await request.response.close();
        });
        final server = await echo();
        final auth = OAuth2Auth(
          tokenUrl: 'http://localhost:${tokens.port}/token',
          clientId: 'id',
          clientSecret: 'secret',
        );
        await protocol.callTool(client, 't', const {}, at(server, auth: auth));
        await protocol.callTool(client, 't', const {}, at(server, auth: auth));
        await protocol.deregisterManual(client, at(server, auth: auth));
        await protocol.callTool(client, 't', const {}, at(server, auth: auth));
        expect(tokenRequests, 1);
        expect(server.requests.map((r) => r.headers.value('authorization')), [
          'Bearer tok',
          'Bearer tok',
        ]);
      },
    );

    test('negotiates the requested subprotocol', () async {
      final server = await serve(
        (socket, frames) =>
            frames.listen((_) => socket.add(socket.protocol ?? 'none')),
        protocolSelector: (offered) =>
            offered.contains('utcp-v1') ? 'utcp-v1' : null,
      );
      expect(
        await protocol.callTool(
          client,
          't',
          const {},
          at(server, subprotocol: 'utcp-v1'),
        ),
        'utcp-v1',
      );
      expect(
        server.requests.single.headers.value('Sec-WebSocket-Protocol'),
        'utcp-v1',
      );
    });

    test('rejects a subprotocol the client did not request', () async {
      // dart:io servers only select offered protocols, so answer by hand.
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          (await upgradeByHand(request, protocol: 'other')).destroy();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(
          client,
          't',
          const {},
          at(server, subprotocol: 'utcp-v1'),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('subprotocol'),
          ),
        ),
      );
    });

    test('never follows a redirect of the upgrade', () async {
      final target = await echo();
      final redirecting = await serve(
        (_, _) {},
        onRequest: (request) async {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://localhost:${target.port}/ws',
            );
          await request.response.close();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(
          client,
          't',
          const {},
          at(
            redirecting,
            auth: const ApiKeyAuth(apiKey: 'secret', varName: 'X-Api-Key'),
          ),
        ),
        throwsA(
          isA<UtcpSecurityException>().having(
            (e) => e.message,
            'message',
            contains('redirect'),
          ),
        ),
      );
      expect(target.requests, isEmpty);
    });

    test('a plain HTTP answer is a handshake failure', () async {
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
    });

    test('a refused connection is a UtcpException without the query', () async {
      final unused = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      final url = 'ws://localhost:$port/ws?token=s3cret';
      await unused.close();
      await expectLater(
        protocol.callTool(
          client,
          't',
          const {},
          WebSocketCallTemplate(url: url),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('ws://localhost:$port/ws'),
              isNot(contains('s3cret')),
            ),
          ),
        ),
      );
    });

    test('a dropped handshake is reported without the query', () async {
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(
          client,
          't',
          const {},
          WebSocketCallTemplate(url: '${server.url}?token=s3cret'),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(contains(server.url), isNot(contains('s3cret'))),
          ),
        ),
      );
    });

    test('rejects a wrong Sec-WebSocket-Accept', () async {
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          request.response
            ..statusCode = HttpStatus.switchingProtocols
            ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
            ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
            ..headers.set('Sec-WebSocket-Accept', 'bm90IHRoZSBrZXk=');
          (await request.response.detachSocket()).destroy();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('Sec-WebSocket-Accept'),
          ),
        ),
      );
    });

    test('a redirect error names its target without the query', () async {
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'wss://elsewhere.example/ws?token=s3cret',
            );
          await request.response.close();
          return true;
        },
      );
      await expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpSecurityException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('wss://elsewhere.example/ws'),
              isNot(contains('s3cret')),
            ),
          ),
        ),
      );
    });

    test('close aborts a handshake the server never answers', () async {
      final arrived = Completer<void>();
      final server = await serve(
        (_, _) {},
        onRequest: (request) {
          arrived.complete();
          return Completer<bool>().future;
        },
      );
      final call = expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      await arrived.future;
      await protocol.close().timeout(const Duration(seconds: 2));
      await call;
    });
  });

  group('discovery', () {
    test('skips frames until a manual arrives', () async {
      late WebSocketTestServer server;
      server = await serve(
        (socket, frames) => frames.listen((_) {
          socket
            ..add('welcome, not json')
            ..add([0, 1])
            ..add('{"type": "hello"}')
            ..add(
              jsonEncode(
                manualFor(server.url, [
                  {'name': 'echo'},
                ]),
              ),
            );
        }),
      );
      final result = await protocol.registerManual(client, at(server));
      expect(result.success, isTrue, reason: '${result.errors}');
      expect(result.manual.tools.single.name, 'echo');
    });

    test(
      'keeps the connection for tool calls with the same handshake',
      () async {
        late WebSocketTestServer server;
        server = await serve(
          serving(
            () => manualFor(server.url, [
              {'name': 'echo'},
            ]),
            respond: (socket, frame) => socket.add('echo:$frame'),
          ),
        );
        await protocol.registerManual(client, at(server));
        expect(
          await protocol.callTool(client, 'ws.echo', {'x': 1}, at(server)),
          'echo:{"x":1}',
        );
        expect(server.sockets, hasLength(1));
      },
    );

    for (final (label, onFrame, timeout)
        in <(String, void Function(WebSocket), Duration)>[
          (
            'the server closes first',
            (s) => unawaited(s.close()),
            const Duration(seconds: 5),
          ),
          ('no manual arrives in time', (_) {}, const Duration(seconds: 1)),
          (
            'the manual is invalid',
            (s) => s.add('{"tools": "nope"}'),
            const Duration(seconds: 5),
          ),
        ]) {
      test('fails, closing its connection, when $label', () async {
        final server = await serve(
          (socket, frames) => frames.listen((_) => onFrame(socket)),
        );
        final closed = server.closed.stream.first;
        final result = await protocol.registerManual(
          client,
          at(server, timeout: timeout),
        );
        expect(result.success, isFalse);
        await closed.timeout(const Duration(seconds: 2));
      });
    }

    test('deregistering closes the manual connection', () async {
      late WebSocketTestServer server;
      server = await serve(serving(() => manualFor(server.url, [])));
      await protocol.registerManual(client, at(server));
      final closed = server.closed.stream.first;
      await protocol.deregisterManual(client, at(server));
      await closed.timeout(const Duration(seconds: 2));
    });
  });

  group('streaming', () {
    test('yields results until stream_end and keeps the connection', () async {
      final server = await serve(
        (socket, frames) => frames.listen((frame) {
          if (frame != '{"q":"go"}') {
            socket.add('single');
            return;
          }
          socket
            ..add(jsonEncode({'type': 'tool_response', 'result': 1}))
            ..add(
              jsonEncode({
                'type': 'tool_response',
                'result': {'n': 2},
              }),
            )
            ..add(
              jsonEncode({
                'type': 'tool_response',
                'request_id': 'other',
                'result': 'skip',
              }),
            )
            ..add('plain text')
            ..add(jsonEncode({'type': 'progress'}))
            ..add(jsonEncode({'type': 'stream_end'}))
            ..add('after the end');
        }),
      );
      final chunks = await protocol.callToolStreaming(client, 't', {
        'q': 'go',
      }, at(server)).toList();
      expect(chunks, [
        1,
        {'n': 2},
        'plain text',
        '{"type":"progress"}',
      ]);
      expect(server.sockets, hasLength(1));
    });

    test('a tool_error fails the stream', () async {
      final server = await serve(
        (socket, frames) => frames.listen((_) {
          socket
            ..add(jsonEncode({'type': 'tool_response', 'result': 'partial'}))
            ..add(jsonEncode({'type': 'tool_error', 'error': 'disk full'}));
        }),
      );
      final chunks = <Object?>[];
      await expectLater(
        protocol
            .callToolStreaming(client, 't', const {}, at(server))
            .forEach(chunks.add),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('disk full'),
          ),
        ),
      );
      expect(chunks, ['partial']);
    });

    test('ends when the server closes', () async {
      final server = await serve(
        (socket, frames) => frames.listen((_) {
          socket.add(jsonEncode({'type': 'tool_response', 'result': 'last'}));
          unawaited(socket.close());
        }),
      );
      expect(
        await protocol
            .callToolStreaming(client, 't', const {}, at(server))
            .toList(),
        ['last'],
      );
    });

    test('times out as a whole', () async {
      final server = await serve(
        (socket, frames) => frames.listen((_) async {
          for (var i = 0; i < 20 && socket.closeCode == null; i++) {
            socket.add(jsonEncode({'type': 'tool_response', 'result': i}));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }),
      );
      await expectLater(
        protocol
            .callToolStreaming(
              client,
              't',
              const {},
              at(server, timeout: const Duration(seconds: 1)),
            )
            .drain<void>(),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });

    test('cancelling mid-stream closes the connection', () async {
      final server = await serve(
        (socket, frames) => frames.listen((_) {
          socket
            ..add(jsonEncode({'type': 'tool_response', 'result': 1}))
            ..add(jsonEncode({'type': 'tool_response', 'result': 2}));
        }),
      );
      final closed = server.closed.stream.first;
      final first = await protocol
          .callToolStreaming(client, 't', const {}, at(server))
          .first;
      expect(first, 1);
      await closed.timeout(const Duration(seconds: 2));
    });
  });

  group('reading', () {
    test('a paused reader stops the server from writing more', () async {
      var written = 0;
      var writing = true;
      final done = Completer<void>();
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          final socket = await upgradeByHand(request);
          socket.listen((_) {}, onError: (Object _) {});
          final frame = serverFrame(1, List.filled(60000, 0x78));
          try {
            while (writing) {
              socket.add(frame);
              await socket.flush();
              written += frame.length;
            }
          } on SocketException {
            // The client closed.
          } finally {
            socket.destroy();
            done.complete();
          }
          return true;
        },
      );
      final frames = StreamIterator(
        protocol.callToolStreaming(client, 't', const {}, at(server)),
      );
      expect(await frames.moveNext(), isTrue);
      await Future<void>.delayed(const Duration(seconds: 1));
      final stalled = written;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Without backpressure loopback carries hundreds of MiB a second; with
      // it the server stops once the socket buffers fill.
      expect(stalled, lessThan(32 * 1024 * 1024));
      expect(written, stalled, reason: 'the server cannot write any more');
      writing = false;
      await frames.cancel();
      await done.future.timeout(const Duration(seconds: 5));
    });

    test('closing waits for the server to answer the close', () async {
      final server = await echo();
      final channel = await connectWebSocket(
        Uri.parse(server.url),
        headers: const {},
        protocol: null,
        pingInterval: null,
        timeout: const Duration(seconds: 5),
        cancel: const Stream.empty(),
      );
      // dart:io gives up on a close frame after 5 s, and until then keeps
      // the socket and any ping timer alive.
      await WebSocketConnection(
        'k',
        channel,
      ).close().timeout(const Duration(seconds: 2));
      expect(channel.closeCode, 1000, reason: "the server's close arrived");
    });

    test('a message larger than the cap fails the call', () async {
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          final socket = await upgradeByHand(request);
          var answered = false;
          // Fragments, so that no single frame is large.
          socket.listen((_) async {
            if (answered) return;
            answered = true;
            final fragment = List.filled(1024 * 1024, 0x78);
            try {
              for (var i = 0; i <= maxMessageBytes ~/ fragment.length; i++) {
                socket.add(serverFrame(i == 0 ? 1 : 0, fragment, fin: false));
                await socket.flush();
              }
              socket.add(serverFrame(0, fragment));
              await socket.flush();
            } on SocketException {
              // The client closed.
            } finally {
              await socket.close();
            }
          }, onError: (Object _) {});
          return true;
        },
      );
      await expectLater(
        protocol.callTool(client, 't', const {}, at(server)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('exceeds 16 MiB'),
          ),
        ),
      );
    });

    test('the cap applies per message, not per connection', () async {
      const messageBytes = 6 * 1024 * 1024;
      var upgrades = 0;
      final server = await serve(
        (_, _) {},
        onRequest: (request) async {
          upgrades++;
          final socket = await upgradeByHand(request);
          addTearDown(socket.close);
          final fragment = List.filled(1024 * 1024, 0x78);
          socket.listen((_) async {
            try {
              final fragments = messageBytes ~/ fragment.length;
              for (var i = 0; i < fragments; i++) {
                socket.add(
                  serverFrame(
                    i == 0 ? 1 : 0,
                    fragment,
                    fin: i == fragments - 1,
                  ),
                );
                await socket.flush();
              }
            } on SocketException {
              // The client closed.
            } on StateError {
              // The client's close frame also reaches this listener.
            }
          }, onError: (Object _) {});
          return true;
        },
      );
      expect(messageBytes * 3, greaterThan(maxMessageBytes));
      for (var i = 0; i < 3; i++) {
        final response = await protocol.callTool(
          client,
          't',
          const {},
          at(server),
        );
        expect(response, hasLength(messageBytes));
      }
      expect(upgrades, 1, reason: 'one connection carried every message');
    });
  });

  test('close() closes every pooled connection', () async {
    final server = await echo();
    await protocol.callTool(client, 't', const {}, at(server));
    await protocol.callTool(
      client,
      't',
      const {},
      at(server, headers: {'X': '1'}),
    );
    expect(server.sockets, hasLength(2));
    final closed = server.closed.stream.take(2).drain<void>();
    await protocol.close();
    await closed.timeout(const Duration(seconds: 2));
  });
}
