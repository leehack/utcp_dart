import '../data/auth.dart';
import '../data/utcp_manual.dart';
import '../exceptions.dart';

final _absoluteOrigin = RegExp(r'^\s*([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#]*)');

/// Loopback per the UTCP HTTP spec: `localhost`, `127.0.0.0/8`, `::1`, the
/// wildcard addresses, and their IPv4-mapped forms. IPv4 is parsed the way
/// `inet_aton` does (`127.1`, `0x7f000001`), since that is how the OS
/// resolver will read it.
bool isLoopbackHost(String host) {
  host = host.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host == 'localhost') return true;
  final v4 = _parseIpv4(host);
  if (v4 != null) return _isLoopbackIpv4(v4);
  if (!host.contains(':')) return false;
  final List<int> bytes;
  try {
    bytes = Uri.parseIPv6Address(host);
  } on FormatException {
    return false;
  }
  final leadingZero = bytes.take(10).every((b) => b == 0);
  if (leadingZero && bytes[10] == 0xff && bytes[11] == 0xff) {
    return _isLoopbackIpv4(bytes.skip(12).fold(0, (v, b) => v * 256 + b));
  }
  return leadingZero &&
      bytes.skip(10).take(5).every((b) => b == 0) &&
      bytes[15] <= 1;
}

bool _isLoopbackIpv4(int address) =>
    address ~/ 0x1000000 == 127 || address == 0;

int? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.isEmpty || parts.length > 4) return null;
  final numbers = <int>[];
  for (final part in parts) {
    final n = switch (part) {
      _ when part.startsWith('0x') => int.tryParse(
        part.substring(2),
        radix: 16,
      ),
      _ when part.length > 1 && part.startsWith('0') => int.tryParse(
        part.substring(1),
        radix: 8,
      ),
      _ => RegExp(r'^\d+$').hasMatch(part) ? int.tryParse(part) : null,
    };
    if (n == null || n < 0) return null;
    numbers.add(n);
  }
  // Arithmetic rather than bit shifts: JavaScript shifts wrap at 32 bits.
  final last = numbers.removeLast();
  var lastLimit = 1;
  for (var i = numbers.length; i < 4; i++) {
    lastLimit *= 256;
  }
  if (numbers.any((n) => n > 255) || last >= lastLimit) return null;
  var address = 0;
  for (final n in numbers) {
    address = address * 256 + n;
  }
  return address * lastLimit + last;
}

Uri? _tryParse(String url) {
  try {
    final uri = Uri.parse(url.trim());
    return uri.hasScheme && uri.host.isNotEmpty ? uri : null;
  } on FormatException {
    return null;
  }
}

bool isLoopbackUrl(String url) {
  final uri = _tryParse(url);
  return uri != null && isLoopbackHost(uri.host);
}

/// The host written literally in a URL template, or `null` when the template
/// is relative or its host is a placeholder.
String? literalTemplateHost(String urlTemplate) {
  final match = _absoluteOrigin.firstMatch(urlTemplate);
  if (match == null) return null;
  final authority = match.group(2)!;
  final hostPort = authority.substring(authority.lastIndexOf('@') + 1);
  final String host;
  if (hostPort.startsWith('[')) {
    final end = hostPort.indexOf(']');
    host = end == -1 ? hostPort.substring(1) : hostPort.substring(1, end);
  } else {
    final colon = hostPort.indexOf(':');
    host = colon == -1 ? hostPort : hostPort.substring(0, colon);
  }
  return host.contains('{') || host.contains('}') ? null : host;
}

/// HTTPS anywhere, or plain HTTP only to a literal loopback address.
bool isSecureUrl(String url) {
  final uri = _tryParse(url);
  if (uri == null) return false;
  return switch (uri.scheme.toLowerCase()) {
    'https' => true,
    'http' => isLoopbackHost(uri.host),
    _ => false,
  };
}

void ensureSecureUrl(String url, String context) {
  if (isSecureUrl(url)) return;
  throw UtcpSecurityException(
    'Security error during $context: URL must use HTTPS or be a literal loopback '
    'address (localhost / 127.0.0.1 / ::1). Got: "$url". Plain HTTP to any other '
    'host is rejected to prevent MITM attacks and SSRF into internal services.',
  );
}

/// Rejects a loopback destination that the template did not name literally,
/// so tool arguments cannot move a request onto the agent's own machine.
void ensureLoopbackWasDeclared(
  String urlTemplate,
  String resolvedUrl,
  String context,
) {
  if (!isLoopbackUrl(resolvedUrl)) return;
  final declared = literalTemplateHost(urlTemplate);
  if (declared != null && isLoopbackHost(declared)) return;
  throw UtcpSecurityException(
    'Security error during $context: "$resolvedUrl" targets a loopback address that '
    'the URL template "$urlTemplate" does not declare.',
  );
}

/// A manual fetched from a remote origin may not point tools or OAuth2 token
/// requests at the agent's loopback interface.
void rejectRemoteLoopbackToolUrls(
  Uri discoveryUrl,
  UtcpManual manual,
  String context,
) {
  if (isLoopbackHost(discoveryUrl.host)) return;
  bool isLoopback(String url) {
    final host = literalTemplateHost(url);
    return isLoopbackUrl(url) || (host != null && isLoopbackHost(host));
  }

  for (final tool in manual.tools) {
    final template = tool.toolCallTemplate;
    for (final endpoint in template.endpoints) {
      if (isLoopback(endpoint)) {
        throw UtcpSecurityException(
          'Security error during $context: a manual fetched from '
          '"${discoveryUrl.scheme}://${discoveryUrl.host}" declares a loopback endpoint '
          '("$endpoint") for tool "${tool.name}".',
        );
      }
    }
    final auth = template.auth;
    if (auth is OAuth2Auth && isLoopback(auth.tokenUrl)) {
      throw UtcpSecurityException(
        'Security error during $context: a manual fetched from '
        '"${discoveryUrl.scheme}://${discoveryUrl.host}" declares a loopback OAuth2 token URL '
        '("${auth.tokenUrl}") for tool "${tool.name}".',
      );
    }
  }
}

void assertNoCrlf(String value, String what) {
  if (value.contains('\r') || value.contains('\n')) {
    throw UtcpSecurityException('$what must not contain CR or LF characters.');
  }
}
