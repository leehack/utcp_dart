import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A loopback WebSocket server. Each upgraded connection is handed to
/// [onConnect] with the frames it receives; [onRequest] may answer a request
/// itself instead of upgrading it.
class WebSocketTestServer {
  WebSocketTestServer._(
    this._server,
    this.onConnect,
    this.onRequest,
    this.protocolSelector,
  ) {
    _server.listen(_serve);
  }

  static Future<WebSocketTestServer> start(
    void Function(WebSocket socket, Stream<Object?> frames) onConnect, {
    Future<bool> Function(HttpRequest request)? onRequest,
    String? Function(List<String> protocols)? protocolSelector,
  }) async => WebSocketTestServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    onConnect,
    onRequest,
    protocolSelector,
  );

  final HttpServer _server;
  final void Function(WebSocket socket, Stream<Object?> frames) onConnect;
  final Future<bool> Function(HttpRequest request)? onRequest;
  final String? Function(List<String> protocols)? protocolSelector;

  /// Handshake requests, in arrival order.
  final requests = <HttpRequest>[];
  final sockets = <WebSocket>[];

  /// Emits once for every connection the client closes.
  final closed = StreamController<void>.broadcast();

  int get port => _server.port;

  String get url => 'ws://localhost:$port/ws';

  Future<void> _serve(HttpRequest request) async {
    requests.add(request);
    if (await onRequest?.call(request) ?? false) return;
    final selector = protocolSelector;
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: selector == null ? null : (p) => selector(p) ?? '',
    );
    sockets.add(socket);
    final frames = StreamController<Object?>();
    socket.listen(
      frames.add,
      onDone: () {
        if (!closed.isClosed) closed.add(null);
        unawaited(frames.close());
      },
    );
    onConnect(socket, frames.stream);
  }

  Future<void> close() async {
    await Future.wait([for (final s in sockets) s.close()]);
    await _server.close(force: true);
    await closed.close();
  }
}

const _toolFields = {'name', 'description', 'tags'};

/// A manual whose tools are all served by [url]. Each entry holds the tool's
/// `name`, `description` and `tags` and its call template's other fields.
Map<String, Object?> manualFor(String url, List<Map<String, Object?>> tools) =>
    {
      'utcp_version': '1.0.1',
      'manual_version': '1.0.0',
      'tools': [
        for (final tool in tools)
          {
            for (final MapEntry(:key, :value) in tool.entries)
              if (_toolFields.contains(key)) key: value,
            'tool_call_template': {
              'call_template_type': 'websocket',
              'url': url,
              for (final MapEntry(:key, :value) in tool.entries)
                if (!_toolFields.contains(key)) key: value,
            },
          },
      ],
    };

/// Answers discovery with [manual] and every other text frame with
/// [respond], when given.
void Function(WebSocket, Stream<Object?>) serving(
  Map<String, Object?> Function() manual, {
  FutureOr<void> Function(WebSocket socket, Object? frame)? respond,
}) => (socket, frames) {
  frames.listen((frame) async {
    if (frame == '{"type": "utcp"}') {
      socket.add(jsonEncode(manual()));
    } else {
      await respond?.call(socket, frame);
    }
  });
};
