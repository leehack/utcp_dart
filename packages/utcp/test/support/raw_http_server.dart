import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One connection to a [RawHttpServer], after the request head arrived.
final class RawExchange {
  RawExchange(this.socket, this.head, this.clientGone);

  final Socket socket;

  /// The request line and headers.
  final String head;

  /// Completes when the client closes the connection.
  final Future<void> clientGone;

  String? header(String name) {
    final prefix = '${name.toLowerCase()}:';
    for (final line in head.split('\r\n')) {
      if (line.toLowerCase().startsWith(prefix)) {
        return line.substring(prefix.length).trim();
      }
    }
    return null;
  }

  /// Writes a response head; without [contentLength] the body runs until the
  /// connection closes.
  Future<void> respond(String contentType, {int? contentLength}) => write(
    'HTTP/1.1 200 OK\r\nContent-Type: $contentType\r\n'
    '${contentLength == null ? '' : 'Content-Length: $contentLength\r\n'}'
    'Connection: close\r\n\r\n',
  );

  Future<void> write(String text) {
    socket.write(text);
    return socket.flush();
  }
}

/// A loopback server speaking raw HTTP/1.1, for what HttpServer cannot do:
/// drop a response mid-body, or notice at once that the client hung up.
final class RawHttpServer {
  RawHttpServer._(this._server, this._handle) {
    _subscription = _server.listen(_accept);
  }

  static Future<RawHttpServer> start(
    Future<void> Function(RawExchange exchange) handle,
  ) async => RawHttpServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    handle,
  );

  final ServerSocket _server;
  final Future<void> Function(RawExchange exchange) _handle;
  late final StreamSubscription<Socket> _subscription;
  final _sockets = <Socket>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  void _accept(Socket socket) {
    _sockets.add(socket);
    socket.done.ignore();
    final head = StringBuffer();
    final gone = Completer<void>();
    var started = false;
    void hungUp() {
      if (!gone.isCompleted) gone.complete();
    }

    socket.listen(
      (bytes) {
        if (started) return;
        head.write(latin1.decode(bytes));
        if (!head.toString().contains('\r\n\r\n')) return;
        started = true;
        unawaited(_handle(RawExchange(socket, head.toString(), gone.future)));
      },
      onDone: hungUp,
      onError: (Object _) => hungUp(),
    );
  }

  Future<void> close() async {
    await _subscription.cancel();
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}
