import 'dart:convert';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'encodings.dart';
import 'python_str.dart';
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
      return arguments.values.map(pythonStr).join(' ');
  }
}

/// Decodes [bytes] with [encoding], or returns them unchanged when
/// [encoding] is null or the bytes are not valid in it.
Object decodeResponse(Uint8List bytes, String? encoding) {
  if (encoding == null) return bytes;
  final decode =
      responseDecoder(encoding) ??
      (throw UtcpException(unsupportedResponseByteFormat(encoding)));
  try {
    return decode(bytes);
  } on FormatException {
    return bytes;
  }
}
