import 'dart:convert';

import 'package:utcp/utcp.dart';

import 'shell_script.dart';

/// What a finished shell process wrote and returned.
typedef ScriptOutput = ({String stdout, String stderr, int exitCode});

/// [output] with the [ShellScript.endMarker] line and anything after it
/// removed from stdout.
///
/// The marker is the last line the script prints, so it is missing only when
/// the script stopped early; anything after it is written by a user `trap
/// '…' EXIT` that runs during shell exit and is dropped. Throws a
/// [UtcpException] when the marker is missing: the selected outputs were
/// never printed. The shell's own stderr (command stderr is captured
/// separately) says why.
ScriptOutput requireFinished(ScriptOutput output, ShellScript script) {
  final marker = script.endMarker;
  if (marker == null) return output;
  final line = '$marker\n';
  final end = output.stdout.indexOf(line);
  if (end >= 0) {
    return (
      stdout: output.stdout.substring(0, end),
      stderr: output.stderr,
      exitCode: output.exitCode,
    );
  }
  final detail = output.stderr.trim();
  throw UtcpException(
    'CLI commands stopped before the script finished (exit code '
    '${output.exitCode}): a command ran `exit` or `exec`, `set -e` stopped '
    'the script, or it has a syntax error.'
    '${detail.isEmpty ? '' : ' Shell error: $detail'}',
  );
}

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
