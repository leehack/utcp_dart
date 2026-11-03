import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'test_server.dart';

/// A legacy HTTP+SSE MCP server (MCP 2024-11-05) on loopback: `GET /sse`
/// opens the event stream and `POST /messages` takes requests. Any other
/// request, such as a streamable HTTP `POST /sse`, gets 404 or 405.
final class LegacySseMcpServer {
  LegacySseMcpServer._(this._http);

  static Future<LegacySseMcpServer> start() async {
    // ignore: deprecated_member_use
    final manager = SseServerManager(
      buildTestServer(
        name: 'sse_server',
        onCrash: () => throw UnsupportedError('crash over SSE'),
      ),
    );
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = LegacySseMcpServer._(http);
    http.listen((request) {
      server.requests.add('${request.method} ${request.uri.path}');
      // ignore: deprecated_member_use
      unawaited(manager.handleRequest(request));
    });
    return server;
  }

  final HttpServer _http;

  /// `METHOD /path` of every request received.
  final requests = <String>[];

  String get url => 'http://127.0.0.1:${_http.port}/sse';

  Future<void> stop() => _http.close(force: true);
}
