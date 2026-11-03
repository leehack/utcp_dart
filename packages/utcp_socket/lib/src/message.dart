import 'dart:convert';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'socket_call_template.dart';

/// Sent to discover a provider's manual. Spelled as Python's `json.dumps`
/// writes it, for servers that compare the request literally.
const discoveryMessage = '{"type": "utcp"}';

final _argPlaceholder = RegExp('UTCP_ARG_(.+?)_UTCP_ARG');

/// Replaces each `UTCP_ARG_<name>_UTCP_ARG` in [template] with the argument
/// [name]: strings as they are, other values as JSON. Placeholders without a
/// matching argument stay as written.
///
/// A template that looks like JSON (starts with `{` or `[`) gets string
/// arguments JSON-escaped, so an argument cannot close the surrounding JSON
/// string and inject fields. Substitution is a single pass, so an argument
/// value cannot introduce placeholders of its own.
String substituteArguments(String template, ToolArguments arguments) {
  final trimmed = template.trimLeft();
  final jsonContext = trimmed.startsWith('{') || trimmed.startsWith('[');
  return template.replaceAllMapped(_argPlaceholder, (match) {
    final name = match.group(1)!;
    if (!arguments.containsKey(name)) return match.group(0)!;
    final value = arguments[name];
    if (value is! String) return jsonEncode(value);
    if (!jsonContext) return value;
    final quoted = jsonEncode(value);
    return quoted.substring(1, quoted.length - 1);
  });
}

/// The request payload for a tool call, per
/// [SocketCallTemplate.requestDataFormat].
String formatRequest(ToolArguments arguments, SocketCallTemplate template) {
  switch (template.requestDataFormat) {
    case RequestDataFormat.json:
      return jsonEncode(arguments);
    case RequestDataFormat.text:
      final text = template.requestDataTemplate;
      if (text != null && text.isNotEmpty) {
        return substituteArguments(text, arguments);
      }
      return [
        for (final value in arguments.values)
          value is String ? value : jsonEncode(value),
      ].join(' ');
  }
}

/// Decodes [bytes] with [encoding], or returns them unchanged when
/// [encoding] is null or the bytes are not valid in it.
Object decodeResponse(Uint8List bytes, String? encoding) {
  if (encoding == null) return bytes;
  // Python spells UTF-8 several ways that Encoding.getByName does not know.
  final name = encoding.toLowerCase().replaceAll('_', '-');
  final codec =
      Encoding.getByName(name == 'utf8' ? 'utf-8' : name) ??
      (throw UtcpException("Unsupported response_byte_format '$encoding'."));
  try {
    return codec.decode(bytes);
  } on FormatException {
    return bytes;
  }
}
