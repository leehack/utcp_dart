import 'package:utcp/utcp.dart';

import 'websocket_call_template.dart';

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
    'ws://[::1]). Got: "$url". Plain WS to any other host is rejected to '
    'prevent MITM attacks and SSRF into internal services.',
  );
}

/// A manual discovered from a remote origin may not point WebSocket or HTTP
/// tools, or their OAuth2 token URLs, at the agent's loopback interface.
void rejectRemoteLoopbackWebSocketTools(
  Uri discoveryUrl,
  UtcpManual manual,
  String context,
) {
  if (isLoopbackHost(discoveryUrl.host)) return;
  rejectRemoteLoopbackToolUrls(discoveryUrl, manual, context);
  bool isLoopback(String url) {
    final host = literalTemplateHost(url);
    return isLoopbackUrl(url) || (host != null && isLoopbackHost(host));
  }

  for (final tool in manual.tools) {
    final template = tool.toolCallTemplate;
    if (template is! WebSocketCallTemplate) continue;
    if (isLoopback(template.url)) {
      throw UtcpSecurityException(
        'Security error during $context: a manual fetched from '
        '"$discoveryUrl" declares a loopback WebSocket URL ("${template.url}") '
        'for tool "${tool.name}".',
      );
    }
    final auth = template.auth;
    if (auth is OAuth2Auth && isLoopback(auth.tokenUrl)) {
      throw UtcpSecurityException(
        'Security error during $context: a manual fetched from '
        '"$discoveryUrl" declares a loopback OAuth2 token URL '
        '("${auth.tokenUrl}") for tool "${tool.name}".',
      );
    }
  }
}
