@Tags(['integration'])
@TestOn('vm')
library;

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import '../support/http_server.dart';

void main() {
  late LoopbackMcpServer server;
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUpAll(silenceMcpLogs);

  setUp(() async {
    server = await LoopbackMcpServer.start();
    protocol = McpCommunicationProtocol();
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
    await server.stop();
  });

  McpCallTemplate manual({String? authToken, Auth? auth}) => McpCallTemplate(
    name: 'remote',
    config: McpConfig(
      mcpServers: {'api': McpHttpServer(url: server.url, authToken: authToken)},
    ),
    auth: auth,
  );

  test('discovers and calls tools over streamable HTTP', () async {
    final template = manual(authToken: 'good');
    final result = await protocol.registerManual(caller, template);
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(result.manual.tools.map((t) => t.name), contains('remote.api.echo'));

    expect(
      await protocol.callTool(caller, 'remote.api.echo', {
        'message': 'http',
      }, template),
      {'reply': 'you said: http'},
    );
    expect(
      await protocol.callTool(caller, 'remote.api.add_numbers', {
        'a': 2,
        'b': 3,
      }, template),
      5,
    );
    await expectLater(
      protocol.callTool(caller, 'remote.api.missing', const {}, template),
      throwsA(isA<UtcpException>()),
    );
  });

  test('fetches an OAuth2 token for the connection', () async {
    final template = manual(
      auth: OAuth2Auth(
        tokenUrl: server.tokenUrl,
        clientId: 'id',
        clientSecret: 'secret',
      ),
    );
    expect(
      await protocol.callTool(caller, 'remote.api.greet', {
        'name': 'Bo',
      }, template),
      'Hello, Bo!',
    );
    await protocol.callTool(caller, 'remote.api.greet', {
      'name': 'Bo',
    }, template);
    expect(server.tokenRequests, 1);
  });

  test('reports rejected credentials as a discovery failure', () async {
    final result = await protocol.registerManual(
      caller,
      manual(authToken: 'bad'),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, startsWith("Server 'api':"));
  });

  test('refuses a plain HTTP server that is not loopback', () async {
    final result = await protocol.registerManual(
      caller,
      const McpCallTemplate(
        name: 'remote',
        config: McpConfig(
          mcpServers: {'api': McpHttpServer(url: 'http://example.com/mcp')},
        ),
      ),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, contains('Security error'));
  });
}
