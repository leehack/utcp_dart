@Tags(['e2e'])
@TestOn('vm && posix')
library;

import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import '../support/http_server.dart';
import '../support/processes.dart';

void main() {
  setUpAll(silenceMcpLogs);

  test(
    'a UtcpClient discovers and calls MCP tools over stdio and HTTP',
    () async {
      final http = await LoopbackMcpServer.start();
      addTearDown(http.stop);
      final stdio = stdioTestServer();

      final client = await UtcpClient.fromJson(
        {
          'variables': {'mcp__tools_SERVER_NAME': 'from_variable'},
          'manual_call_templates': [
            {
              'name': 'mcp-tools',
              'call_template_type': 'mcp',
              'config': {
                'mcpServers': {
                  'local': {
                    'command': stdio.command,
                    'args': stdio.args,
                    'env': {r'MCP_SERVER_NAME': r'${SERVER_NAME}'},
                  },
                  'remote': {
                    'transport': 'http',
                    'url': http.url,
                    'auth_token': 'good',
                  },
                },
              },
            },
          ],
        },
        protocols: [McpCommunicationProtocol()],
      );
      addTearDown(client.close);

      final names = (await client.getTools()).map((t) => t.name);
      expect(
        names,
        containsAll(['mcp_tools.local.echo', 'mcp_tools.remote.echo']),
      );

      expect(await client.callTool('mcp_tools.local.echo', {'message': 'a'}), {
        'reply': 'you said: a',
      });
      expect(
        await client.callTool('mcp_tools.remote.greet', {'name': 'b'}),
        'Hello, b!',
      );
      final whoami = asJsonMap(
        await client.callTool('mcp_tools.local.whoami'),
        'whoami',
      );
      expect(whoami['server'], 'from_variable');
      expect(
        await client.callToolStreaming('mcp_tools.local.add_numbers', {
          'a': 1,
          'b': 2,
        }).toList(),
        [3],
      );

      final pid = whoami.optInt('pid')!;
      expect(await client.deregisterManual('mcp_tools'), isTrue);
      await waitForExit(pid);
      await expectLater(
        client.callTool('mcp_tools.local.echo', {'message': 'gone'}),
        throwsA(isA<UtcpException>()),
      );
    },
  );

  test('client.close terminates the MCP child process', () async {
    final stdio = stdioTestServer();
    final client = await UtcpClient.fromJson(
      {
        'manual_call_templates': [
          {
            'name': 'local',
            'call_template_type': 'mcp',
            'config': {
              'mcpServers': {
                'tools': {'command': stdio.command, 'args': stdio.args},
              },
            },
          },
        ],
      },
      protocols: [McpCommunicationProtocol()],
    );
    final whoami = asJsonMap(
      await client.callTool('local.tools.whoami'),
      'whoami',
    );
    await client.close();
    await waitForExit(whoami.optInt('pid')!);
  });

  test('the example runs end to end', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_mcp_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Found weather.local.get_weather'));
    expect(result.stdout, contains('{city: Seoul, temperature_c: 21}'));
  });
}
