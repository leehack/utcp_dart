import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:utcp/utcp.dart';

import 'mcp_call_template.dart';

/// Fails: without `dart:io` there are no child processes. A
/// [UtcpException], so discovery reports it as a failed server and a tool
/// call throws it, like any other unreachable server.
mcp.Transport openStdioTransport(McpStdioServer server) =>
    throw const UtcpException(
      'stdio MCP servers need a native platform (the Dart VM or Flutter on '
      'desktop or mobile); on the web, use a streamable HTTP server.',
    );

/// Always false: without `dart:io` nothing raises an `IOException`.
bool isIOException(Object error) => false;
