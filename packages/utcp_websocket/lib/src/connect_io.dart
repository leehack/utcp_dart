import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'describe.dart';

const _acceptGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
final _random = Random.secure();

/// The most bytes read from the socket without a complete message arriving.
/// `dart:io` assembles a whole message, every fragment of it, in memory
/// before delivering it, so this caps the size of one message (control
/// frames in between count against it too).
const maxMessageBytes = 16 * 1024 * 1024;

/// Opens a WebSocket from the Dart VM.
///
/// The handshake is done here rather than by `WebSocket.connect`, which
/// follows redirects of the upgrade request and would carry the handshake
/// headers (credentials included) to a host the URL check never saw. Like a
/// browser, this refuses any redirect.
///
/// The channel reads the `dart:io` [WebSocket] directly, so pausing its
/// stream stops reading the socket and TCP flow control pushes back on the
/// server. (`IOWebSocketChannel` keeps reading into a buffer of its own.)
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
  final client = HttpClient()..connectionTimeout = timeout;
  final meter = _MessageMeter(uri);
  final handshake = _handshake(client, uri, headers, protocol, meter);
  final cancelled = Completer<WebSocket>();
  final cancelling = cancel.listen((_) {
    if (cancelled.isCompleted) return;
    cancelled.completeError(
      UtcpException('Connecting to ${describeUrl(uri)} was cancelled.'),
    );
  });
  var connected = false;
  try {
    // Closed through the returned channel.
    // ignore: close_sinks
    final webSocket = await Future.any([
      handshake,
      cancelled.future,
    ]).timeout(timeout);
    connected = true;
    return _IoWebSocketChannel(webSocket..pingInterval = pingInterval, meter);
  } on TimeoutException {
    throw UtcpException(
      'Connecting to ${describeUrl(uri)} timed out after '
      '${timeout.inSeconds} s.',
    );
  } on HttpException catch (e) {
    // Its toString appends the full URL, query string included.
    throw UtcpException(
      'Could not connect to ${describeUrl(uri)}: ${e.message}',
    );
  } on IOException catch (e) {
    throw UtcpException('Could not connect to ${describeUrl(uri)}: $e');
  } finally {
    await cancelling.cancel();
    // A detached socket outlives the client; anything else is torn down.
    client.close(force: !connected);
    if (!connected) {
      // A handshake that completes after a timeout or cancel is not used.
      unawaited(
        handshake.then((socket) => socket.close(), onError: (Object _) {}),
      );
    }
  }
}

Future<WebSocket> _handshake(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  String? protocol,
  _MessageMeter meter,
) async {
  final key = base64Encode([for (var i = 0; i < 16; i++) _random.nextInt(256)]);
  final request = await client.openUrl(
    'GET',
    uri.replace(scheme: uri.scheme.toLowerCase() == 'wss' ? 'https' : 'http'),
  );
  request.followRedirects = false;
  headers.forEach(
    (name, value) => request.headers.set(name, value, preserveHeaderCase: true),
  );
  request.headers
    ..set(HttpHeaders.connectionHeader, 'Upgrade')
    ..set(HttpHeaders.upgradeHeader, 'websocket')
    ..set('Sec-WebSocket-Key', key)
    ..set('Sec-WebSocket-Version', '13');
  if (protocol != null) request.headers.set('Sec-WebSocket-Protocol', protocol);
  final response = await request.close();

  final url = describeUrl(uri);
  final status = response.statusCode;
  if (status >= 300 && status < 400) {
    throw UtcpSecurityException(
      'Security error during WebSocket connection: the upgrade request to '
      '"$url" was answered with HTTP $status redirecting to '
      '"${describeUrlString(response.headers.value(HttpHeaders.locationHeader) ?? '')}". A redirect '
      'of the upgrade is never followed; connect to the real WebSocket URL.',
    );
  }
  final upgrade = response.headers.value(HttpHeaders.upgradeHeader);
  final connection = response.headers[HttpHeaders.connectionHeader] ?? [];
  if (status != HttpStatus.switchingProtocols ||
      upgrade?.toLowerCase() != 'websocket' ||
      !connection.any((v) => v.toLowerCase().contains('upgrade'))) {
    throw UtcpException(
      'WebSocket handshake with "$url" failed: HTTP $status without an '
      'upgrade.',
    );
  }
  final expected = base64Encode(
    sha1.convert(utf8.encode('$key$_acceptGuid')).bytes,
  );
  if (response.headers.value('Sec-WebSocket-Accept') != expected) {
    throw UtcpException(
      'WebSocket handshake with "$url" failed: bad Sec-WebSocket-Accept.',
    );
  }
  final selected = response.headers.value('Sec-WebSocket-Protocol');
  if (selected != null && selected != protocol) {
    throw UtcpException(
      'WebSocket server "$url" selected subprotocol "$selected", which was '
      'not requested.',
    );
  }
  return WebSocket.fromUpgradedSocket(
    _MeteredSocket(await response.detachSocket(), meter),
    protocol: selected,
    serverSide: false,
  );
}

/// Counts the bytes read since the last complete message.
final class _MessageMeter {
  _MessageMeter(this._uri);

  final Uri _uri;
  var _unread = 0;
  UtcpException? exceeded;

  Uint8List read(Uint8List chunk) {
    _unread += chunk.length;
    if (_unread > maxMessageBytes) {
      throw exceeded ??= UtcpException(
        'A message from ${describeUrl(_uri)} exceeds '
        '${maxMessageBytes ~/ (1024 * 1024)} MiB.',
      );
    }
    return chunk;
  }

  void delivered() => _unread = 0;
}

/// A socket whose incoming bytes pass through a [_MessageMeter]. Throwing
/// from the meter makes the `dart:io` WebSocket fail with a protocol error
/// and close.
final class _MeteredSocket extends StreamView<Uint8List> implements Socket {
  _MeteredSocket(this._socket, _MessageMeter meter)
    : super(_socket.map(meter.read));

  final Socket _socket;

  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  InternetAddress get address => _socket.address;
  @override
  int get port => _socket.port;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  int get remotePort => _socket.remotePort;
  @override
  Future<void> get done => _socket.done;

  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future<void> close() => _socket.close();
  @override
  void destroy() => _socket.destroy();
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}

/// A [WebSocketChannel] that reads [WebSocket] directly, so a paused
/// subscription pauses the socket.
final class _IoWebSocketChannel
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _IoWebSocketChannel(this._webSocket, _MessageMeter meter)
    : sink = _IoWebSocketSink(_webSocket),
      stream = _webSocket.transform(
        StreamTransformer<Object?, Object?>.fromHandlers(
          handleData: (message, sink) {
            meter.delivered();
            sink.add(message);
          },
          handleDone: (sink) {
            final exceeded = meter.exceeded;
            if (exceeded != null) sink.addError(exceeded);
            sink.close();
          },
        ),
      );

  final WebSocket _webSocket;

  @override
  final Stream<Object?> stream;
  @override
  final WebSocketSink sink;
  @override
  String? get protocol => _webSocket.protocol;
  @override
  int? get closeCode => _webSocket.closeCode;
  @override
  String? get closeReason => _webSocket.closeReason;
  @override
  Future<void> get ready => Future.value();
}

final class _IoWebSocketSink implements WebSocketSink {
  _IoWebSocketSink(this._webSocket);

  final WebSocket _webSocket;

  @override
  void add(Object? data) => _webSocket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _webSocket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<Object?> stream) =>
      _webSocket.addStream(stream);
  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _webSocket.close(closeCode, closeReason);
  @override
  Future<void> get done => _webSocket.done;
}
