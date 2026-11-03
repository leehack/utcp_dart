import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'describe.dart';

const _acceptGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
final _random = Random.secure();

/// Opens a WebSocket from the Dart VM.
///
/// The handshake is done here rather than by `WebSocket.connect`, which
/// follows redirects of the upgrade request and would carry the handshake
/// headers (credentials included) to a host the URL check never saw. Like a
/// browser, this refuses any redirect.
Future<WebSocketChannel> connectWebSocket(
  Uri uri, {
  required Map<String, String> headers,
  required String? protocol,
  required Duration? pingInterval,
  required Duration timeout,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  var connected = false;
  try {
    // Closed through the returned channel.
    // ignore: close_sinks
    final webSocket = await _handshake(
      client,
      uri,
      headers,
      protocol,
    ).timeout(timeout);
    connected = true;
    return IOWebSocketChannel(webSocket..pingInterval = pingInterval);
  } on TimeoutException {
    throw UtcpException(
      'Connecting to ${describeUrl(uri)} timed out after '
      '${timeout.inSeconds} s.',
    );
  } on IOException catch (e) {
    throw UtcpException('Could not connect to ${describeUrl(uri)}: $e');
  } finally {
    // A detached socket outlives the client; anything else is torn down.
    client.close(force: !connected);
  }
}

Future<WebSocket> _handshake(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  String? protocol,
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
      '"${response.headers.value(HttpHeaders.locationHeader)}". A redirect '
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
    await response.detachSocket(),
    protocol: selected,
    serverSide: false,
  );
}
