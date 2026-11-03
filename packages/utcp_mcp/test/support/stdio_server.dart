import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'test_server.dart';

/// Runs [buildTestServer] over stdio. `MCP_SERVER_NAME` names the server, and
/// its `crash` tool ends the process.
Future<void> main() async {
  final server = buildTestServer(
    name: Platform.environment['MCP_SERVER_NAME'] ?? 'stdio_server',
    onCrash: () => exit(3),
    whoami: () => {'pid': pid, 'cwd': Directory.current.path},
  );
  await server.connect(StdioServerTransport());
}
