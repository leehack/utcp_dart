import 'dart:convert';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'socket_call_template.dart';

/// The request payload for a tool call, per
/// [SocketCallTemplate.requestDataFormat].
String formatRequest(ToolArguments arguments, SocketCallTemplate template) {
  switch (template.requestDataFormat) {
    case RequestDataFormat.json:
      return jsonEncode(arguments);
    case RequestDataFormat.text:
      final text = template.requestDataTemplate;
      if (text != null && text.isNotEmpty) {
        return substituteArgumentPlaceholders(text, arguments);
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
