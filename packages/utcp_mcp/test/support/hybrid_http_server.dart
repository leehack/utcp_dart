import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:stream_channel/stream_channel.dart';

import 'http_server.dart';

/// Runs [LoopbackMcpServer] on the VM for a browser test, plus an endpoint
/// that redirects to it, and sends their URLs. Stops when the test closes
/// the channel.
Future<void> hybridMain(StreamChannel<Object?> channel) async {
  silenceMcpLogs();
  final server = await LoopbackMcpServer.start();
  final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  redirect.listen((request) async {
    // Preflights pass, so a failure is the browser refusing the redirect
    // itself, not CORS.
    final preflight = request.method == 'OPTIONS';
    request.response
      ..statusCode = preflight
          ? HttpStatus.noContent
          : HttpStatus.temporaryRedirect
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..headers.set(
        'Access-Control-Allow-Headers',
        request.headers.value('access-control-request-headers') ?? '',
      )
      ..headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE');
    if (!preflight) request.response.headers.set('Location', server.url);
    await request.response.close();
  });
  channel.sink.add({
    'url': server.url,
    'tokenUrl': server.tokenUrl,
    'redirectUrl': 'http://127.0.0.1:${redirect.port}/mcp',
  });
  await channel.stream.drain<void>();
  await redirect.close(force: true);
  await server.stop();
}
