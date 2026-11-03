import 'dart:async';

import 'package:test/test.dart';
import 'package:utcp_websocket/src/websocket_connection.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

void main() {
  late WebSocket server;
  late WebSocketConnection connection;

  setUp(() async {
    final (client, peer) = fakes();
    server = peer;
    final channel = AdapterWebSocketChannel(client);
    await channel.ready;
    connection = WebSocketConnection('k', channel);
  });

  tearDown(() => connection.close());

  Future<Object?> next() =>
      connection.next(DateTime.now().add(const Duration(seconds: 5)));

  test('drops frames that arrive between exchanges', () async {
    server.sendText('unsolicited');
    await pumpEventQueue();
    connection.send('q');
    server.sendText('answer');
    expect(await next(), 'answer');
  });

  test('a frame received before send never answers it', () async {
    connection.send('q1');
    server
      ..sendText('answer-1')
      ..sendText('trailer-1');
    expect(await next(), 'answer-1');
    await pumpEventQueue();
    expect(connection.bufferedFrames, 1);

    connection.send('q2');
    expect(connection.bufferedFrames, 0);
    server.sendText('answer-2');
    expect(await next(), 'answer-2');
  });

  test('releasing the connection ends the exchange', () async {
    final release = await connection.acquire(const Duration(seconds: 5));
    connection.send('q1');
    server
      ..sendText('answer-1')
      ..sendText('trailer-1');
    expect(await next(), 'answer-1');
    await pumpEventQueue();
    release();
    expect(connection.bufferedFrames, 0);
    server.sendText('late');
    await pumpEventQueue();
    expect(connection.bufferedFrames, 0);
  });

  test('a holder that keeps the connection times a waiter out', () async {
    final release = await connection.acquire(const Duration(seconds: 5));
    await expectLater(
      connection.acquire(const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    var acquired = false;
    final next = connection
        .acquire(const Duration(seconds: 5))
        .then((r) => acquired = true);
    await pumpEventQueue();
    expect(acquired, isFalse, reason: 'still held');
    release();
    await next;
  });

  test('pauses reading while too many frames wait', () async {
    connection.send('go');
    for (var i = 0; i < 100; i++) {
      server.sendText('$i');
    }
    await pumpEventQueue();
    expect(connection.bufferedFrames, WebSocketConnection.maxBufferedFrames);
    expect(connection.isPaused, isTrue);
    expect(
      [for (var i = 0; i < 100; i++) await next()],
      [for (var i = 0; i < 100; i++) '$i'],
    );
    expect(connection.isPaused, isFalse);
  });

  test('pauses reading while too many bytes wait', () async {
    connection.send('go');
    final big = 'x' * (WebSocketConnection.maxBufferedBytes ~/ 2);
    for (var i = 0; i < 4; i++) {
      server.sendText(big);
    }
    await pumpEventQueue();
    expect(connection.bufferedFrames, 2);
    expect(connection.isPaused, isTrue);
    for (var i = 0; i < 4; i++) {
      expect(await next(), hasLength(big.length));
    }
  });

  test('reports the close of the connection', () async {
    connection.send('q');
    await server.close();
    expect(await next(), isNull);
    expect(connection.isClosed, isTrue);
  });
}
