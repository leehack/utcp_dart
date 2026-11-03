import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'test_server.dart';

/// A legacy HTTP+SSE MCP server that speaks only MCP 2024-11-05, on
/// loopback: `GET /sse` opens the event stream and `POST /messages` takes
/// requests. Any other request, such as a streamable HTTP `POST /sse`, gets
/// 404 or 405.
final class LegacySseMcpServer {
  LegacySseMcpServer._(this._http, this._mcp);

  static const protocolVersion = '2024-11-05';

  static Future<LegacySseMcpServer> start() async {
    final mcp = buildTestServer(
      name: 'sse_server',
      onCrash: () => throw UnsupportedError('crash over SSE'),
      options: const _LegacyOptions(),
    );
    // ignore: deprecated_member_use
    final manager = SseServerManager(mcp);
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = LegacySseMcpServer._(http, mcp);
    http.listen((request) {
      server.requests.add('${request.method} ${request.uri.path}');
      if (request.headers.value('mcp-protocol-version') case final version?) {
        server.protocolVersions.add(version);
      }
      // ignore: deprecated_member_use
      unawaited(manager.handleRequest(request));
    });
    return server;
  }

  final HttpServer _http;
  final McpServer _mcp;

  /// `METHOD /path` of every request received.
  final requests = <String>[];

  /// The `MCP-Protocol-Version` header of every request that had one.
  final protocolVersions = <String>[];

  /// The client that completed the `initialize` handshake, if any.
  Implementation? get initializedClient => _mcp.server.getClientVersion();

  String get url => 'http://127.0.0.1:${_http.port}/sse';

  Future<void> stop() => _http.close(force: true);
}

/// The [McpProtocol.legacy] profile, narrowed to 2024-11-05, the last
/// version whose servers use HTTP+SSE.
final class _LegacyOptions extends McpServerOptions {
  const _LegacyOptions() : super(protocol: McpProtocol.legacy);

  @override
  List<String> get supportedVersions => const [
    LegacySseMcpServer.protocolVersion,
  ];
}
