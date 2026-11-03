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
    'Security error during $context: ${_insecureUrlMessage(url)}',
  );
}

final _variablePlaceholder = RegExp(r'\$\{\w+\}|\$\w+');

/// Throws a [FormatException] when [url], as written in a call template,
/// can never pass [ensureSecureWebSocketUrl].
///
/// Variables are substituted only when the template is used, so each
/// `${VAR}` is checked as a value that is not loopback: `wss://${HOST}` and
/// `ws://localhost:${PORT}` pass, `ws://${HOST}` does not. The connection
/// checks the substituted URL again.
void checkWebSocketUrlTemplate(String url) {
  if (isSecureWebSocketUrl(url.replaceAll(_variablePlaceholder, '1'))) return;
  throw FormatException("Field 'url': ${_insecureUrlMessage(url)}");
}

String _insecureUrlMessage(String url) =>
    'WebSocket URL must use WSS or be a literal loopback address '
    '(ws://localhost / ws://127.0.0.1 / ws://[::1]). '
    'Got: "${describeUrlString(url)}". Plain WS to any other host is '
    'rejected to prevent MITM attacks and SSRF into internal services.';
