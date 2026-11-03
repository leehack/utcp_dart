import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/src/connect.dart' as generic;
import 'package:utcp_websocket/utcp_websocket.dart';

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
}
