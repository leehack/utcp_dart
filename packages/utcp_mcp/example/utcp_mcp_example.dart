import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

/// Registers an MCP server that runs as a child process and calls its tool.
Future<void> main() async {
  silenceMcpLogs();
  final server = Platform.script.resolve('weather_server.dart').toFilePath();
  final client = await UtcpClient.fromJson(
    {
      'manual_call_templates': [
        {
          'name': 'weather',
          'call_template_type': 'mcp',
          'config': {
            'mcpServers': {
              'local': {
                'command': Platform.resolvedExecutable,
                'args': [server],
              },
            },
          },
        },
      ],
    },
    protocols: [McpCommunicationProtocol()],
  );
  try {
    for (final tool in await client.getTools()) {
      print('Found ${tool.name}: ${tool.description}');
    }
    final result = await client.callTool('weather.local.get_weather', {
      'city': 'Seoul',
    });
    print(result);
  } finally {
    await client.close();
  }
}
