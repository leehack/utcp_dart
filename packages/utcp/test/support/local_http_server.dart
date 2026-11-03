import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A loopback HTTP server whose responses come from [handle]. Requests are
/// recorded, bodies included.
class LocalHttpServer {
  LocalHttpServer._(this._server, this.handle) {
    _subscription = _server.listen(_serve);
  }

  static Future<LocalHttpServer> start(
    FutureOr<void> Function(HttpRequest request, String body) handle,
  ) async => LocalHttpServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    handle,
  );

  final HttpServer _server;
  final FutureOr<void> Function(HttpRequest request, String body) handle;
  late final StreamSubscription<HttpRequest> _subscription;
  final requests =
      <({String method, Uri uri, HttpHeaders headers, String body})>[];

  String get baseUrl => 'http://localhost:${_server.port}';

  Future<void> _serve(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    requests.add((
      method: request.method,
      uri: request.uri,
      headers: request.headers,
      body: body,
    ));
    await handle(request, body);
    await request.response.close();
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

extension JsonResponse on HttpResponse {
  void json(Object? body, {int status = 200}) {
    statusCode = status;
    headers.contentType = ContentType.json;
    write(jsonEncode(body));
  }
}
