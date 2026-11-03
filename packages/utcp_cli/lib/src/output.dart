import 'dart:convert';

import 'package:utcp/utcp.dart';

import 'shell_script.dart';

/// What a finished shell process wrote and returned.
typedef ScriptOutput = ({String stdout, String stderr, int exitCode});

/// [output] with the [ShellScript.endMarker] line and anything after it
/// removed from stdout.
///
/// The marker is the last line the script prints; anything after it is
/// written by a user `trap '…' EXIT` and is dropped. It is missing when the
/// script stopped early: a command ended it (`exit`, `exec`, `set -e`), or
/// the shell hit a syntax error. Then the outputs printed so far are followed
/// by [stoppedCommandOutput] (empty when the shell stopped between commands)
/// and the shell's own stderr, such as a syntax error, since the spec returns
/// a failing script's output instead of an error.
Future<ScriptOutput> finishedOutput(
  ScriptOutput output,
  ShellScript script,
  Future<String> Function() stoppedCommandOutput,
) async {
  final marker = script.endMarker;
  if (marker == null) return output;
  final end = output.stdout.indexOf('$marker\n');
  final stdout = end >= 0
      ? output.stdout.substring(0, end)
      : '${output.stdout}${await stoppedCommandOutput()}${output.stderr}';
  return (stdout: stdout, stderr: output.stderr, exitCode: output.exitCode);
}

/// The text a script produced: for bash, stdout unless it is blank (every
/// command's stderr is captured into it), else the shell's stderr; for
/// PowerShell, stderr when the exit code is non-zero. Both match the
/// reference SDKs.
String scriptText(ScriptOutput output, Shell shell) => switch (shell) {
  Shell.bash => output.stdout.trim().isNotEmpty ? output.stdout : output.stderr,
  Shell.powershell => output.exitCode == 0 ? output.stdout : output.stderr,
};

/// The tool result of [output]: decoded JSON when the trimmed [scriptText]
/// starts with `{` or `[` and parses, otherwise the trimmed text. A failing
/// command's error text is returned, not thrown.
Object? parseToolOutput(ScriptOutput output, Shell shell) {
  final text = scriptText(output, shell).trim();
  if (text.startsWith('{') || text.startsWith('[')) {
    if (_tryDecode(text) case final Object json) return json;
  }
  return text;
}

/// A manual read from discovery output, and why any tool in it was skipped.
typedef DiscoveredManual = ({UtcpManual manual, List<String> skipped});

/// Parses discovery output as the Python SDK does: the whole output as a
/// UTCP manual, a list of tools or a single tool; otherwise every line that
/// is a JSON object, where the first manual wins and single tools are
/// collected. A tool that does not parse is skipped, with the reason in
/// `skipped`.
///
/// Throws a [FormatException] when no manual or tool is found, or when every
/// tool was skipped.
DiscoveredManual parseManualOutput(String output) {
  final skipped = <String>[];
  DiscoveredManual result(UtcpManual manual) {
    if (manual.tools.isEmpty && skipped.isNotEmpty) {
      throw FormatException('No valid tools. ${skipped.join(' ')}');
    }
    return (manual: manual, skipped: skipped);
  }

  if (_manualOrTools(_tryDecode(output.trim()), skipped) case final manual?) {
    return result(manual);
  }
  final tools = <Tool>[];
  for (final line in const LineSplitter().convert(output)) {
    final text = line.trim();
    if (!text.startsWith('{') || !text.endsWith('}')) continue;
    switch (_tryDecode(text)) {
      case {'tools': final List<Object?> list} && final JsonMap json:
        return result(_manual(json, list, skipped));
      case final json:
        tools.addAll(_manualOrTools(json, skipped)?.tools ?? const []);
    }
  }
  if (tools.isNotEmpty || skipped.isNotEmpty) {
    return result(UtcpManual(tools: tools));
  }
  throw const FormatException('Discovery output is not a UTCP manual.');
}

/// [json] as a manual: an object with a `tools` list, a list of tools, or
/// one tool (an object with `name` and `description`); null otherwise.
UtcpManual? _manualOrTools(Object? json, List<String> skipped) =>
    switch (json) {
      {'tools': final List<Object?> list} && final JsonMap manual => _manual(
        manual,
        list,
        skipped,
      ),
      final List<Object?> list => UtcpManual(tools: _tools(list, skipped)),
      final JsonMap tool
          when tool.containsKey('name') && tool.containsKey('description') =>
        UtcpManual(tools: _tools([tool], skipped)),
      _ => null,
    };

/// [json] read by [UtcpManual.fromJson], with [tools] parsed one by one.
UtcpManual _manual(JsonMap json, List<Object?> tools, List<String> skipped) {
  final header = UtcpManual.fromJson({...json, 'tools': const <Object?>[]});
  return UtcpManual(
    utcpVersion: header.utcpVersion,
    manualVersion: header.manualVersion,
    tools: _tools(tools, skipped),
  );
}

List<Tool> _tools(List<Object?> items, List<String> skipped) => [
  for (final (i, item) in items.indexed)
    if (_tool(item, i, skipped) case final Tool tool) tool,
];

Tool? _tool(Object? item, int index, List<String> skipped) {
  try {
    return Tool.fromJson(asJsonMap(item, 'Tool $index'));
  } on FormatException catch (e) {
    final name = item is Map<String, Object?> && item['name'] is String
        ? " '${item['name']}'"
        : '';
    skipped.add('Skipped tool $index$name: ${e.message}');
    return null;
  }
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
