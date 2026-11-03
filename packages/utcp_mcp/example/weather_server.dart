import 'package:mcp_dart/mcp_dart.dart';

/// A one-tool MCP server over stdio, started by `utcp_mcp_example.dart`.
Future<void> main() async {
  final server =
      McpServer(const Implementation(name: 'weather', version: '1.0.0'))
        ..registerTool(
          'get_weather',
          description: 'Current weather for a city',
          inputSchema: JsonSchema.object(
            properties: {'city': JsonSchema.string()},
            required: ['city'],
          ),
          callback: (args, extra) => CallToolResult.fromStructuredContent({
            'city': args['city'],
            'temperature_c': 21,
          }),
        );
  await server.connect(StdioServerTransport());
}
