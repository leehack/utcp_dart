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

  test('a 404 also falls back, and the fallback session is reused', () async {
    final template = manual({
      'transport': 'http',
      'url': server.url.replaceFirst('/sse', '/missing'),
    });
    final result = await protocol.registerManual(caller, template);
    expect(result.success, isFalse);
    expect(server.requests, ['POST /missing', 'GET /missing']);

    await expectWorks(manual({'url': server.url}));
    final opened = server.requests.where((r) => r == 'GET /sse').length;
    await protocol.callTool(caller, 'legacy.api.echo', {
      'message': 'again',
    }, manual({'url': server.url}));
    expect(server.requests.where((r) => r == 'GET /sse').length, opened);
  });
}
