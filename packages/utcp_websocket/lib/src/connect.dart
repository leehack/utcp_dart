import 'dart:async';

import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'describe.dart';

/// Opens a WebSocket where `dart:io` is unavailable. Browsers never follow
/// a redirect of the handshake, and cannot send handshake headers or pings.
///
/// An event on [cancel] aborts a handshake in progress.
Future<WebSocketChannel> connectWebSocket(
  Uri uri, {
  required Map<String, String> headers,
  required String? protocol,
  required Duration? pingInterval,
  required Duration timeout,
  required Stream<void> cancel,
}) async {
  if (headers.isNotEmpty) {
    throw UtcpException(
      'This platform cannot send WebSocket handshake headers '
      '(${headers.keys.join(', ')}). Use query-string auth or connect from '
      'the Dart VM.',
    );
  }
  final channel = WebSocketChannel.connect(
    uri,
    protocols: protocol == null ? null : [protocol],
  );
  final cancelled = Completer<void>();
  final cancelling = cancel.listen((_) {
    if (cancelled.isCompleted) return;
    cancelled.completeError(
      UtcpException('Connecting to ${describeUrl(uri)} was cancelled.'),
    );
  });
  try {
    await Future.any([channel.ready, cancelled.future]).timeout(timeout);
    return channel;
  } on UtcpException {
    unawaited(channel.sink.close());
    rethrow;
  } on TimeoutException {
    unawaited(channel.sink.close());
    throw UtcpException(
      'Connecting to ${describeUrl(uri)} timed out after '
      '${timeout.inSeconds} s.',
    );
  } on WebSocketChannelException catch (e) {
    throw UtcpException('Could not connect to ${describeUrl(uri)}: $e');
  } finally {
    await cancelling.cancel();
  }
}
