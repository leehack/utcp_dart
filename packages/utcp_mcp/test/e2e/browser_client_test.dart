@Tags(['e2e'])
@TestOn('browser')
library;

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  setUpAll(silenceMcpLogs);

  test(
    'a UtcpClient in a browser calls HTTP MCP tools and reports stdio ones',
    () async {
      final hybrid = spawnHybridUri('../support/hybrid_http_server.dart');
      addTearDown(hybrid.sink.close);
      final urls = asJsonMap(await hybrid.stream.first, 'hybrid server');

      final client = await UtcpClient.fromJson(
        {
          'variables': {'remote_MCP_TOKEN': 'good'},
          'manual_call_templates': [
            {
              'name': 'remote',
              'call_template_type': 'mcp',
              'config': {
                'mcpServers': {
                  'api': {
                    'transport': 'http',
                    'url': urls.string('url'),
                    'auth_token': r'${MCP_TOKEN}',
                  },
                },
              },
            },
          ],
        },
        protocols: [McpCommunicationProtocol()],
      );
      addTearDown(client.close);

      expect(
        (await client.getTools()).map((t) => t.name),
        contains('remote.api.echo'),
      );
      expect(await client.callTool('remote.api.echo', {'message': 'web'}), {
        'reply': 'you said: web',
      });
      expect(
        await client.callToolStreaming('remote.api.add_numbers', {
          'a': 1,
          'b': 2,
        }).toList(),
        [3],
      );

      final local = await client.registerManual(
        CallTemplate.fromJson({
          'name': 'local',
          'call_template_type': 'mcp',
          'config': {
            'mcpServers': {
              'files': {'command': 'mcp-files'},
            },
          },
        }),
      );
      expect(local.success, isFalse);
      expect(local.errors.single, contains('need a native platform'));
      expect(
        (await client.getTools()).map((t) => t.name),
        everyElement(startsWith('remote.')),
      );
    },
  );
}
