import 'dart:convert';

import 'data/tool.dart';

/// Sent to discover a manual over a message transport (`tcp`, `udp`,
/// `websocket`). Spelled as Python's `json.dumps` writes it, for servers
/// that compare the request literally.
const utcpDiscoveryMessage = '{"type": "utcp"}';

final _argPlaceholder = RegExp('UTCP_ARG_(.+?)_UTCP_ARG');
final _jsonShaped = RegExp(r'^\s*[{[]');

/// Replaces each `UTCP_ARG_<name>_UTCP_ARG` in [template] with the argument
/// `name`: strings as they are, other values as JSON. Placeholders without a
/// matching argument stay as written.
///
/// With [jsonEscape], string arguments are JSON-escaped so they cannot close
/// a surrounding JSON string and inject fields. When it is null, they are
/// escaped if [template] looks like JSON (starts with `{` or `[`).
/// Substitution is a single pass, so an argument value cannot introduce
/// placeholders of its own.
String substituteArgumentPlaceholders(
  String template,
  ToolArguments arguments, {
  bool? jsonEscape,
}) {
  final escape = jsonEscape ?? _jsonShaped.hasMatch(template);
  return template.replaceAllMapped(_argPlaceholder, (match) {
    final name = match.group(1)!;
    if (!arguments.containsKey(name)) return match.group(0)!;
    final value = arguments[name];
    if (value is! String) return jsonEncode(value);
    if (!escape) return value;
    final quoted = jsonEncode(value);
    return quoted.substring(1, quoted.length - 1);
  });
}
