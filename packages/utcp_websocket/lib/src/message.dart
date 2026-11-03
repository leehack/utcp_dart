import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:utcp/utcp.dart';

import 'websocket_call_template.dart';

final _log = Logger('utcp.websocket');

/// Sent to discover a provider's manual, spelled as the Python transport
/// writes it.
const discoveryMessage = '{"type": "utcp"}';

final _argPlaceholder = RegExp('UTCP_ARG_(.+?)_UTCP_ARG');

/// The text frame sent for a tool call.
///
/// Without a template the arguments are sent as one JSON object. A string
/// template that looks like JSON (starts with `{` or `[`) gets its string
/// arguments JSON-escaped, so an argument cannot close the surrounding JSON
/// string and inject fields; an object template is encoded after
/// substitution, which escapes them anyway.
String formatMessage(Object? template, ToolArguments arguments) =>
    switch (template) {
      null => jsonEncode(arguments),
      String() => _substitute(
        template,
        arguments,
        jsonEscape: RegExp(r'^\s*[{[]').hasMatch(template),
      ),
      _ => jsonEncode(_substituteDeep(template, arguments)),
    };

Object? _substituteDeep(Object? value, ToolArguments arguments) =>
    switch (value) {
      String() => _substitute(value, arguments, jsonEscape: false),
      Map<Object?, Object?>() => {
        for (final MapEntry(:key, :value) in value.entries)
          '$key': _substituteDeep(value, arguments),
      },
      List<Object?>() => [
        for (final item in value) _substituteDeep(item, arguments),
      ],
      _ => value,
    };

/// Replaces each `UTCP_ARG_<name>_UTCP_ARG` with the argument [name]:
/// strings as they are (or JSON-escaped), other values as JSON. Placeholders
/// without a matching argument stay as written. A single pass, so an
/// argument value cannot introduce placeholders of its own.
String _substitute(
  String template,
  ToolArguments arguments, {
  required bool jsonEscape,
}) => template.replaceAllMapped(_argPlaceholder, (match) {
  final name = match.group(1)!;
  if (!arguments.containsKey(name)) return match.group(0)!;
  final value = arguments[name];
  if (value is! String) return jsonEncode(value);
  if (!jsonEscape) return value;
  final quoted = jsonEncode(value);
  return quoted.substring(1, quoted.length - 1);
});

/// A received frame as a tool result: text per [format], binary as bytes.
Object? decodeMessage(Object? data, WebSocketResponseFormat? format) {
  if (data is List<int>) {
    return data is Uint8List ? data : Uint8List.fromList(data);
  }
  if (data is String && format == WebSocketResponseFormat.json) {
    try {
      return jsonDecode(data);
    } on FormatException {
      _log.warning('Expected a JSON response; returning it as text.');
    }
  }
  return data;
}
