@Tags(['integration'])
@TestOn('browser')
library;

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  late StreamChannel<Object?> hybrid;
  late JsonMap urls;
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUpAll(() async {
    silenceMcpLogs();
    hybrid = spawnHybridUri('../support/hybrid_http_server.dart');
    urls = asJsonMap(await hybrid.stream.first, 'hybrid server');
  });

  tearDownAll(() => hybrid.sink.close());

  setUp(() async {
    protocol = McpCommunicationProtocol();
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
  });

  McpCallTemplate manual({String? url, String? authToken, Auth? auth}) =>
      McpCallTemplate(
        name: 'remote',
        config: McpConfig(
          mcpServers: {
            'api': McpHttpServer(
              url: url ?? urls.string('url'),
              authToken: authToken,
            ),
          },
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
        'message': 'browser',
      }, template),
      {'reply': 'you said: browser'},
    );
    expect(
      await protocol.callTool(caller, 'remote.api.whoami', const {}, template),
      {'server': 'http_server'},
    );
  });

  test('fetches an OAuth2 token for the connection', () async {
    final template = manual(
      auth: OAuth2Auth(
        tokenUrl: urls.string('tokenUrl'),
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
  });

  test('reports rejected credentials as a discovery failure', () async {
    final result = await protocol.registerManual(
      caller,
      manual(authToken: 'bad'),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, startsWith("Server 'api':"));
  });

  test('refuses any redirect, which browsers cannot re-validate', () async {
    final result = await protocol.registerManual(
      caller,
      manual(url: urls.string('redirectUrl'), authToken: 'good'),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, startsWith("Server 'api':"));
    expect(result.errors.single, isNot(contains('good')));
  });

  test('refuses a plain HTTP server that is not loopback', () async {
    final result = await protocol.registerManual(
      caller,
      manual(url: 'http://example.com/mcp'),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, contains('Security error'));
  });
}
