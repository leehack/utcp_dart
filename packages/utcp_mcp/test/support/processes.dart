import 'dart:io';

import 'package:utcp_mcp/utcp_mcp.dart';

/// The stdio test server run by this Dart VM.
McpStdioServer stdioTestServer({
  Map<String, String> env = const {},
  String? cwd,
}) => McpStdioServer(
  command: Platform.resolvedExecutable,
  args: [File('test/support/stdio_server.dart').absolute.path],
  env: env,
  cwd: cwd,
);

/// Whether [pid] is a running process. Sending SIGCONT is harmless.
bool isRunning(int pid) => Process.killPid(pid, ProcessSignal.sigcont);

/// Waits for [pid] to exit, failing after [timeout].
Future<void> waitForExit(
  int pid, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (isRunning(pid)) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Process $pid is still running.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
