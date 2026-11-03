import 'package:utcp/utcp.dart';

import 'describe.dart';

/// `wss://` anywhere, or plain `ws://` only to a literal loopback address:
/// the WebSocket form of [isSecureUrl].
bool isSecureWebSocketUrl(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url.trim());
  } on FormatException {
    return false;
  }
  if (uri.host.isEmpty) return false;
  return switch (uri.scheme.toLowerCase()) {
    'wss' => true,
    'ws' => isLoopbackHost(uri.host),
    _ => false,
  };
}

/// Throws a [UtcpSecurityException] unless [isSecureWebSocketUrl] accepts
/// [url].
void ensureSecureWebSocketUrl(String url, String context) {
  if (isSecureWebSocketUrl(url)) return;
  throw UtcpSecurityException(
    'Security error during $context: WebSocket URL must use WSS or be a '
    'literal loopback address (ws://localhost / ws://127.0.0.1 / '
    'ws://[::1]). Got: "${describeUrlString(url)}". Plain WS to any other host is rejected to '
    'prevent MITM attacks and SSRF into internal services.',
  );
}
