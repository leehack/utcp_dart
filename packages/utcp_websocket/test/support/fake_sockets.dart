import 'dart:async';

import 'package:utcp_websocket/utcp_websocket.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A [WebSocketConnector] that connects to in-memory servers: [onText]
/// handles each text frame the client sends to a server end.
final class FakeSockets {
  FakeSockets([this.onText]);

  final void Function(WebSocket server, String text)? onText;

  /// Every handshake, in order.
  final handshakes = <({Uri uri, Map<String, String> headers})>[];

  /// Server ends whose client has not closed yet.
  final servers = <WebSocket>{};

  int get open => servers.length;

  Future<WebSocketChannel> call(
    Uri uri,
    Map<String, String> headers,
    WebSocketCallTemplate template,
    Stream<void> cancel,
  ) async {
    handshakes.add((uri: uri, headers: headers));
    final (client, server) = fakes();
    servers.add(server);
    server.events.listen((event) {
      if (event is TextDataReceived) onText?.call(server, event.text);
    }, onDone: () => servers.remove(server));
    final channel = AdapterWebSocketChannel(client);
    await channel.ready;
    return channel;
  }
}
