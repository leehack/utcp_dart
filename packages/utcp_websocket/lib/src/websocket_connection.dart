import 'dart:async';
import 'dart:collection';

import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// One WebSocket, used for one exchange at a time.
///
/// Frames carry no correlation id, so only frames that arrive after
/// [send] belong to the exchange: earlier ones are discarded on [send], and
/// frames arriving between exchanges are dropped. Reading pauses while
/// [maxBufferedFrames] frames or [maxBufferedBytes] are waiting, which
/// bounds the buffer and pushes back on the server.
final class WebSocketConnection {
  WebSocketConnection(this.key, this._channel) {
    _subscription = _channel.stream.listen(
      _receive,
      onError: (Object error) {
        _error ??= error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  static const maxBufferedFrames = 16;
  static const maxBufferedBytes = 4 * 1024 * 1024;

  /// Identifies the handshake this connection was opened with.
  final String key;
  final WebSocketChannel _channel;
  late final StreamSubscription<Object?> _subscription;
  final _inbox = Queue<Object?>();
  var _bufferedBytes = 0;
  var _paused = false;
  var _exchanging = false;
  Completer<void>? _waiter;
  Object? _error;
  var _done = false;
  Future<void> _tail = Future.value();
  Future<void>? _closing;

  bool get isClosed => _done || _error != null;

  /// Frames received for the current exchange and not read yet.
  int get bufferedFrames => _inbox.length;

  /// Whether reading is paused because the buffer is full.
  bool get isPaused => _paused;

  /// Waits for earlier holders, then returns the function that releases
  /// the connection to the next one.
  Future<void Function()> acquire() async {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    await previous;
    return () {
      endExchange();
      released.complete();
    };
  }

  /// Starts an exchange by sending [text]. Frames received before it are
  /// discarded.
  void send(String text) {
    _clear();
    _exchanging = true;
    _channel.sink.add(text);
  }

  /// Ends the exchange; frames from now until the next [send] are dropped.
  void endExchange() {
    _exchanging = false;
    _clear();
  }

  /// The next frame (a `String` or `List<int>`), or null once the
  /// connection has closed. Throws a [TimeoutException] at [deadline].
  Future<Object?> next(DateTime deadline) async {
    while (_inbox.isEmpty) {
      final error = _error;
      if (error != null) throw UtcpException('WebSocket error: $error');
      if (_done) return null;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException(null);
      await (_waiter ??= Completer<void>()).future.timeout(remaining);
    }
    final frame = _inbox.removeFirst();
    _bufferedBytes -= _size(frame);
    _resumeIfRoom();
    return frame;
  }

  void _receive(Object? frame) {
    if (!_exchanging) return;
    _inbox.add(frame);
    _bufferedBytes += _size(frame);
    if (!_paused &&
        (_inbox.length >= maxBufferedFrames ||
            _bufferedBytes >= maxBufferedBytes)) {
      _paused = true;
      _subscription.pause();
    }
    _wake();
  }

  void _clear() {
    _inbox.clear();
    _bufferedBytes = 0;
    _resumeIfRoom();
  }

  void _resumeIfRoom() {
    if (_paused &&
        _inbox.length < maxBufferedFrames &&
        _bufferedBytes < maxBufferedBytes) {
      _paused = false;
      _subscription.resume();
    }
  }

  static int _size(Object? frame) => switch (frame) {
    String() => frame.length,
    List<int>() => frame.length,
    _ => 0,
  };

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _done = true;
    _wake();
    await _subscription.cancel();
    await _channel.sink
        .close(status.normalClosure)
        .timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}
