@Tags(['integration'])
@TestOn('vm')
library;

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import '../support/legacy_sse_server.dart';

void main() {
  late LegacySseMcpServer server;
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUpAll(silenceMcpLogs);

  setUp(() async {
    server = await LegacySseMcpServer.start();
    protocol = McpCommunicationProtocol();
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
    await server.stop();
  });

  McpCallTemplate manual(JsonMap serverConfig) => McpCallTemplate.fromJson({
    'name': 'legacy',
    'call_template_type': 'mcp',
    'config': {
      'mcpServers': {'api': serverConfig},
    },
  });

  Future<void> expectWorks(McpCallTemplate template) async {
    final result = await protocol.registerManual(caller, template);
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(result.manual.tools.map((t) => t.name), contains('legacy.api.echo'));
    expect(
      await protocol.callTool(caller, 'legacy.api.echo', {
        'message': 'sse',
      }, template),
      {'reply': 'you said: sse'},
    );
    expect(server.initializedClient?.name, 'utcp_mcp');
    expect(server.protocolVersions.last, LegacySseMcpServer.protocolVersion);
  }

  test('type: sse speaks only the legacy transport', () async {
    await expectWorks(manual({'type': 'sse', 'url': server.url}));
    expect(server.requests.first, 'GET /sse');
    expect(server.requests, isNot(contains('POST /sse')));
  });

  test('a streamable HTTP server that answers 405 falls back to SSE', () async {
    await expectWorks(manual({'url': server.url}));
    expect(server.requests.take(2), ['POST /sse', 'GET /sse']);
  });

  test('a 404 also falls back, and a failed fallback names both '
      'statuses', () async {
    const secret = 'secret-token-value';
    final result = await protocol.registerManual(
      caller,
      manual({
        'url': '${server.url.replaceFirst('/sse', '/missing')}?key=$secret',
        'headers': {'X-Api-Key': secret},
        'auth_token': secret,
      }),
    );
    expect(result.success, isFalse);
    expect(server.requests, ['POST /missing', 'GET /missing']);
    expect(
      result.errors.single,
      allOf(
        contains('streamable HTTP answered 404'),
        contains('legacy HTTP+SSE transport failed'),
        contains('(HTTP 404)'),
        isNot(contains(secret)),
      ),
    );
  });

  test('the fallback session is reused', () async {
    final template = manual({'url': server.url});
    await expectWorks(template);
    await protocol.callTool(caller, 'legacy.api.echo', {
      'message': 'again',
    }, template);
    expect(server.requests.where((r) => r == 'GET /sse'), hasLength(1));
    expect(server.requests.where((r) => r == 'POST /sse'), hasLength(1));
  });
}
