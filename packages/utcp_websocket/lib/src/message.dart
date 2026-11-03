import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:utcp/utcp.dart';

import 'websocket_call_template.dart';

final _log = Logger('utcp.websocket');

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
      String() => substituteArgumentPlaceholders(template, arguments),
      _ => jsonEncode(_substituteDeep(template, arguments)),
    };

Object? _substituteDeep(Object? value, ToolArguments arguments) =>
    switch (value) {
      String() => substituteArgumentPlaceholders(
        value,
        arguments,
        jsonEscape: false,
      ),
      Map<Object?, Object?>() => {
        for (final MapEntry(:key, :value) in value.entries)
          '$key': _substituteDeep(value, arguments),
      },
      List<Object?>() => [
        for (final item in value) _substituteDeep(item, arguments),
      ],
      _ => value,
    };

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
