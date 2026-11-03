import 'dart:convert';

import 'package:utcp/utcp.dart';

import 'shell_script.dart';

/// What a finished shell process wrote and returned.
typedef ScriptOutput = ({String stdout, String stderr, int exitCode});

/// The tool result of [output]: decoded JSON when the trimmed text starts
/// with `{` or `[` and parses, otherwise the trimmed text.
///
/// Bash scripts capture every command's stderr, so stdout is used unless it
/// is blank; for PowerShell stderr is used when the exit code is non-zero.
/// Both match the reference SDKs, which return a failing command's error
/// text instead of throwing.
Object? parseToolOutput(ScriptOutput output, Shell shell) {
  final text = switch (shell) {
    Shell.bash =>
      output.stdout.trim().isNotEmpty ? output.stdout : output.stderr,
    Shell.powershell => output.exitCode == 0 ? output.stdout : output.stderr,
  }.trim();
  if (text.startsWith('{') || text.startsWith('[')) {
    if (_tryDecode(text) case final Object json) return json;
  }
  return text;
}

/// Parses discovery output as a UTCP manual: the whole output, or else the
/// first line that is a JSON object with a `tools` list (so log lines around
/// the manual are tolerated, as in the Python SDK).
///
/// Throws a [FormatException] when no manual is found.
UtcpManual parseManualOutput(String output) {
  if (_tryDecode(output.trim()) case final Object json) {
    return UtcpManual.fromJson(asJsonMap(json, 'Discovery output'));
  }
  for (final line in const LineSplitter().convert(output)) {
    final text = line.trim();
    if (!text.startsWith('{') || !text.endsWith('}')) continue;
    if (_tryDecode(text) case final Map<String, Object?> json
        when json['tools'] is List<Object?>) {
      return UtcpManual.fromJson(json);
    }
  }
  throw const FormatException('Discovery output is not a UTCP manual.');
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
