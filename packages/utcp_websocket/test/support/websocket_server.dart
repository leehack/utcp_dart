import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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

/// Answers [request] with a WebSocket upgrade, selecting [protocol], and
/// returns the raw socket, for servers that write frames by hand.
Future<Socket> upgradeByHand(HttpRequest request, {String? protocol}) {
  final key = request.headers.value('Sec-WebSocket-Key')!;
  final accept = base64Encode(
    sha1
        .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
        .bytes,
  );
  request.response
    ..statusCode = HttpStatus.switchingProtocols
    ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
    ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
    ..headers.set('Sec-WebSocket-Accept', accept);
  if (protocol != null) {
    request.response.headers.set('Sec-WebSocket-Protocol', protocol);
  }
  return request.response.detachSocket();
}

/// An unmasked server frame: text when [opcode] is 1, a continuation when 0.
List<int> serverFrame(int opcode, List<int> payload, {bool fin = true}) {
  final length = payload.length;
  return [
    (fin ? 0x80 : 0) | opcode,
    if (length < 126)
      length
    else if (length < 0x10000) ...[
      126,
      length >> 8,
      length & 0xff,
    ] else ...[
      127,
      for (var shift = 56; shift >= 0; shift -= 8) (length >> shift) & 0xff,
    ],
    ...payload,
  ];
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
