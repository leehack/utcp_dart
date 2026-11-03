import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import 'mcp_call_template.dart';
import 'mcp_communication_protocol.dart' show McpCommunicationProtocol;

/// A transport that runs [server] as a child process once started.
mcp.Transport openStdioTransport(McpStdioServer server) {
  final inherit =
      Platform.environment[McpCommunicationProtocol.childStderrVariable] ==
      'inherit';
  return mcp.StdioClientTransport(
    mcp.StdioServerParameters(
      command: server.command,
      args: server.args,
      environment: server.env,
      workingDirectory: server.cwd,
      stderrMode: inherit
          ? ProcessStartMode.inheritStdio
          : ProcessStartMode.normal,
      // A dead child is replaced by a fresh session, not restarted behind
      // the session's back.
      restartOnUnexpectedExit: false,
    ),
  );
}

/// Whether [error] is a process or pipe failure of a stdio server.
bool isIOException(Object error) => error is IOException;
