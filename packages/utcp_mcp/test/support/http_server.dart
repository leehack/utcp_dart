import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'test_server.dart';

/// A streamable HTTP MCP server on loopback that accepts `Bearer good`, plus
/// an OAuth2 token endpoint that issues that token.
final class LoopbackMcpServer {
  LoopbackMcpServer._(this._mcp, this._tokens);

  static Future<LoopbackMcpServer> start() async {
    final tokens = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late final LoopbackMcpServer server;
    final mcp = StreamableMcpServer(
      serverFactory: (_) => buildTestServer(
        name: 'http_server',
        onCrash: () => throw UnsupportedError('crash over HTTP'),
      ),
      host: '127.0.0.1',
      port: 0,
      // Object? because analysis sees mcp_dart's web stub, typed dynamic.
      authenticator: (Object? request) =>
          request is HttpRequest &&
          request.headers.value('authorization') == 'Bearer good',
    );
    server = LoopbackMcpServer._(mcp, tokens);
    tokens.listen((request) async {
      server.tokenRequests++;
      final form = Uri.splitQueryString(
        await utf8.decoder.bind(request).join(),
      );
      final ok = form['client_secret'] == 'secret';
      request.response
        ..statusCode = ok ? 200 : 401
        ..headers.contentType = ContentType.json
        // Browser tests fetch tokens from another origin.
        ..headers.set('Access-Control-Allow-Origin', '*')
        ..write(jsonEncode(ok ? {'access_token': 'good'} : {'error': 'no'}));
      await request.response.close();
    });
    await mcp.start();
    return server;
  }

  final StreamableMcpServer _mcp;
  final HttpServer _tokens;

  int tokenRequests = 0;

  String get url => 'http://127.0.0.1:${_mcp.boundPort}/mcp';

  String get tokenUrl => 'http://127.0.0.1:${_tokens.port}/token';

  Future<void> stop() async {
    await _mcp.stop();
    await _tokens.close(force: true);
  }
}
