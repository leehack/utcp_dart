import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';

/// A loopback TCP server that hands each connection to [handle], which reads
/// requests from the queue and writes to the socket.
class TcpTestServer {
  TcpTestServer._(this._server, this.handle) {
    _server.listen(_serve);
  }

  static Future<TcpTestServer> start(
    Future<void> Function(Socket socket, StreamQueue<List<int>> input) handle,
  ) async => TcpTestServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    handle,
  );

  final ServerSocket _server;
  final Future<void> Function(Socket, StreamQueue<List<int>>) handle;
  final _sockets = <Socket>{};

  /// Completes once per connection when the client closes its side.
  final clientClosed = StreamController<void>.broadcast();

  int get port => _server.port;

  Future<void> _serve(Socket socket) async {
    _sockets.add(socket);
    final input = StreamQueue(socket);
    try {
      await handle(socket, input);
      while (await input.hasNext) {
        await input.next;
      }
      clientClosed.add(null);
    } on SocketException {
      clientClosed.add(null);
    } finally {
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
    await clientClosed.close();
  }
}

/// A loopback UDP server that hands each datagram to [handle].
class UdpTestServer {
  UdpTestServer._(this.socket, this.handle) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        received.add(d);
        handle(socket, d);
      }
    });
  }

  static Future<UdpTestServer> start(
    void Function(RawDatagramSocket socket, Datagram request) handle,
  ) async => UdpTestServer._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    handle,
  );

  final RawDatagramSocket socket;
  final void Function(RawDatagramSocket, Datagram) handle;
  final received = <Datagram>[];

  int get port => socket.port;

  void close() => socket.close();
}
