import 'dart:convert';
import 'dart:io' show Directory, pid;

import 'package:mcp_dart/mcp_dart.dart';

/// An MCP server with one tool per result shape the transport maps, plus a
/// resource. [name] is echoed by the `whoami` tool so tests can tell servers
/// apart, and the `crash` tool runs [onCrash] to drop the connection while a
/// call is in flight.
McpServer buildTestServer({
  String name = 'test_server',
  required Future<CallToolResult> Function() onCrash,
}) {
  final server = McpServer(Implementation(name: name, version: '1.0.0'));
  server
    ..registerTool(
      'echo',
      description: 'This tool echoes back its input',
      inputSchema: JsonSchema.object(
        properties: {'message': JsonSchema.string()},
        required: ['message'],
      ),
      outputSchema: JsonSchema.object(
        properties: {'reply': JsonSchema.string()},
      ),
      callback: (args, extra) => CallToolResult.fromStructuredContent({
        'reply': 'you said: ${args['message']}',
      }),
    )
    ..registerTool(
      'greet',
      description: 'Greets a person without structured output',
      inputSchema: JsonSchema.object(properties: {'name': JsonSchema.string()}),
      callback: (args, extra) => CallToolResult.fromContent([
        TextContent(text: 'Hello, ${args['name']}!'),
      ]),
    )
    ..registerTool(
      'list_items',
      description: 'Returns a list wrapped the way FastMCP wraps it',
      inputSchema: JsonSchema.object(
        properties: {'count': JsonSchema.integer()},
      ),
      callback: (args, extra) {
        final count = switch (args['count']) {
          final int n => n,
          _ => 0,
        };
        return CallToolResult.fromStructuredContent({
          'result': [for (var i = 0; i < count; i++) 'item_$i'],
        });
      },
    )
    ..registerTool(
      'add_numbers',
      description: 'Adds two numbers and returns the sum as text',
      inputSchema: JsonSchema.object(
        properties: {'a': JsonSchema.number(), 'b': JsonSchema.number()},
      ),
      callback: (args, extra) {
        num number(String key) => switch (args[key]) {
          final num n => n,
          _ => 0,
        };
        final (a, b) = (number('a'), number('b'));
        return CallToolResult.fromContent([TextContent(text: '${a + b}')]);
      },
    )
    ..registerTool(
      'mixed',
      description: 'Returns text, JSON text and an image',
      inputSchema: JsonSchema.object(),
      callback: (args, extra) => CallToolResult.fromContent([
        const TextContent(text: 'plain'),
        TextContent(text: jsonEncode({'k': 1})),
        const ImageContent(data: 'aGk=', mimeType: 'image/png'),
      ]),
    )
    ..registerTool(
      'fail',
      description: 'Reports a tool error',
      inputSchema: JsonSchema.object(),
      callback: (args, extra) => const CallToolResult(
        content: [TextContent(text: 'boom')],
        isError: true,
      ),
    )
    ..registerTool(
      'whoami',
      description: 'Returns the server name, process id and directory',
      inputSchema: JsonSchema.object(),
      callback: (args, extra) => CallToolResult.fromStructuredContent({
        'server': name,
        'pid': pid,
        'cwd': Directory.current.path,
      }),
    )
    ..registerTool(
      'crash',
      description: 'Drops the connection mid-call',
      inputSchema: JsonSchema.object(),
      callback: (args, extra) => onCrash(),
    )
    ..registerTool(
      'quota',
      description: 'Fails with a server-defined JSON-RPC error',
      inputSchema: JsonSchema.object(),
      callback: (args, extra) => throw McpError(-32000, 'Quota exceeded'),
    )
    ..registerResource(
      'test_document',
      'file:///test_document.txt',
      (description: 'A test document', mimeType: 'text/plain'),
      (uri, extra) => ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: 'This is a test document.',
          ),
        ],
      ),
    );
  return server;
}
