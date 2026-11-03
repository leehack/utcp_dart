import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import 'test_server.dart';

/// Connects each session to a fresh in-memory [buildTestServer], named after
/// the configured server, and records every connection.
final class InMemoryServers {
  final connections = <String>[];
  final _servers = <McpServer>[];
  final _controllers = <StreamController<List<int>>>[];

  /// Server names whose connection attempts fail.
  final failing = <String>{};

  /// How often a `crash` tool has run.
  int crashes = 0;

  /// Client transports handed out and not closed yet.
  int open = 0;

  FutureOr<Transport> call(
    String serverName,
    McpServerConfig server,
    Auth? auth,
  ) async {
    if (failing.contains(serverName)) {
      throw UtcpException('server $serverName is down');
    }
    connections.add(serverName);
    final [toServer, toClient] = [
      for (var i = 0; i < 2; i++) StreamController<List<int>>(),
    ];
    _controllers.addAll([toServer, toClient]);
    final mcpServer = buildTestServer(
      name: serverName,
      onCrash: () {
        crashes++;
        unawaited(toClient.close());
        return Completer<CallToolResult>().future;
      },
    );
    _servers.add(mcpServer);
    await mcpServer.connect(
      IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
    );
    open++;
    return _CountedTransport(
      stream: toClient.stream,
      sink: toServer.sink,
      onClose: () => open--,
    );
  }

  /// Drops every live connection, as if each server process died.
  Future<void> killAll() async {
    for (final server in _servers) {
      await server.close();
    }
    for (final controller in _controllers) {
      await controller.close();
    }
    _servers.clear();
    _controllers.clear();
  }

  Future<void> close() => killAll();
}

/// A manual with one in-memory server per name in [servers].
McpCallTemplate inMemoryManual(
  List<String> servers, {
  String name = 'manual',
  bool resources = false,
  Auth? auth,
}) => McpCallTemplate(
  name: name,
  config: McpConfig(
    mcpServers: {
      for (final server in servers) server: McpStdioServer(command: server),
    },
  ),
  auth: auth,
  registerResourcesAsTools: resources,
);

final class _CountedTransport extends IOStreamTransport {
  _CountedTransport({
    required super.stream,
    required super.sink,
    required this.onClose,
  });

  final void Function() onClose;
  bool _counted = false;

  @override
  Future<void> close() {
    if (!_counted) {
      _counted = true;
      onClose();
    }
    return super.close();
  }
}
