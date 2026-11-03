@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

import '../support/servers.dart';

void main() {
  late UtcpClient client;
  final protocol = TcpCommunicationProtocol();

  setUpAll(() async => client = await UtcpClient.create(protocols: [protocol]));
  tearDownAll(() => client.close());

  Future<TcpTestServer> serve(
    Future<void> Function(Socket socket, List<int> request) respond,
  ) async {
    final server = await TcpTestServer.start(
      (socket, input) async => respond(socket, await input.next),
    );
    addTearDown(server.close);
    return server;
  }

  TcpCallTemplate at(
    TcpTestServer server, {
    TcpFramingStrategy framing = TcpFramingStrategy.stream,
    int? fixedLength,
    String? responseByteFormat = 'utf-8',
    Duration timeout = const Duration(seconds: 5),
  }) => TcpCallTemplate(
    name: 'svc',
    host: 'localhost',
    port: server.port,
    framingStrategy: framing,
    lengthPrefixBytes: 2,
    messageDelimiter: r'\n',
    fixedMessageLength: fixedLength,
    responseByteFormat: responseByteFormat,
    timeout: timeout,
  );

  test('length-prefix framing in both directions', () async {
    late List<int> received;
    final server = await serve((socket, request) async {
      received = request;
      socket.add([0, 2, ...utf8.encode('ok')]);
    });
    final result = await protocol.callTool(client, 'svc.t', {
      'a': 1,
    }, at(server, framing: TcpFramingStrategy.lengthPrefix));
    expect(result, 'ok');
    expect(received, [0, 7, ...utf8.encode('{"a":1}')]);
  });

  test(
    'delimiter framing reassembles a response split across writes',
    () async {
      late List<int> received;
      final server = await serve((socket, request) async {
        received = request;
        socket.add(utf8.encode('hel'));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        socket.add(utf8.encode('lo\nignored\n'));
      });
      final result = await protocol.callTool(client, 'svc.t', {
        'q': 'x',
      }, at(server, framing: TcpFramingStrategy.delimiter));
      expect(result, 'hello');
      expect(utf8.decode(received), '{"q":"x"}\n');
    },
  );

  test('fixed-length framing returns raw bytes without an encoding', () async {
    final server = await serve(
      (socket, _) async => socket.add([1, 2, 3, 4, 5]),
    );
    final result = await protocol.callTool(
      client,
      'svc.t',
      const {},
      at(
        server,
        framing: TcpFramingStrategy.fixedLength,
        fixedLength: 4,
        responseByteFormat: null,
      ),
    );
    expect(result, [1, 2, 3, 4]);
  });

  test('stream framing reads until the server closes', () async {
    final server = await serve((socket, _) async {
      socket.add(utf8.encode('all '));
      socket.add(utf8.encode('of it'));
      await socket.close();
    });
    expect(
      await protocol.callTool(client, 'svc.t', const {}, at(server)),
      'all of it',
    );
  });

  test(
    'stream framing returns what arrived once the server goes quiet',
    () async {
      final server = await serve(
        (socket, _) async => socket.add(utf8.encode('partial')),
      );
      final result = await protocol.callTool(
        client,
        'svc.t',
        const {},
        at(server, timeout: const Duration(milliseconds: 200)),
      );
      expect(result, 'partial');
    },
  );

  test('a silent server times out and the client closes its socket', () async {
    final server = await serve((_, _) async {});
    final closed = server.clientClosed.stream.first;
    await expectLater(
      protocol.callTool(
        client,
        'svc.t',
        const {},
        at(
          server,
          framing: TcpFramingStrategy.delimiter,
          timeout: const Duration(milliseconds: 200),
        ),
      ),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
    await closed.timeout(const Duration(seconds: 2));
  });

  test('a server disconnecting mid-response is an error', () async {
    final server = await serve((socket, _) async {
      socket.add([0, 10, 1, 2]);
      await socket.close();
    });
    await expectLater(
      protocol.callTool(
        client,
        'svc.t',
        const {},
        at(server, framing: TcpFramingStrategy.lengthPrefix),
      ),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
  });

  test('the client closes its socket after a successful call', () async {
    final server = await serve(
      (socket, _) async => socket.add(utf8.encode('x\n')),
    );
    final closed = server.clientClosed.stream.first;
    await protocol.callTool(
      client,
      'svc.t',
      const {},
      at(server, framing: TcpFramingStrategy.delimiter),
    );
    await closed.timeout(const Duration(seconds: 2));
  });

  test('connection refused is a UtcpException', () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    await expectLater(
      protocol.callTool(
        client,
        't',
        const {},
        TcpCallTemplate(host: '127.0.0.1', port: port),
      ),
      throwsA(isA<UtcpException>()),
    );
  });

  test('discovers a manual over the configured framing', () async {
    late String request;
    final server = await serve((socket, bytes) async {
      request = utf8.decode(bytes);
      socket.add(
        utf8.encode(
          '${jsonEncode({
            'utcp_version': '1.0.1',
            'tools': [
              {'name': 'echo'},
            ],
          })}\n',
        ),
      );
    });
    final result = await protocol.registerManual(
      client,
      at(server, framing: TcpFramingStrategy.delimiter),
    );
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(request, '{"type": "utcp"}\n');
    expect(result.manual.tools.single.name, 'echo');
  });

  test('a failed discovery is reported, not thrown', () async {
    final server = await serve((socket, _) async {
      socket.add(utf8.encode('not json'));
      await socket.close();
    });
    final result = await protocol.registerManual(client, at(server));
    expect(result.success, isFalse);
  });
}
