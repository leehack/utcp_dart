import 'package:utcp/utcp.dart';

import 'literal.dart';

/// The kinds of UTCP document the corpus holds, by what parses them.
enum DocumentKind {
  /// `UtcpClientConfig`.
  clientConfig('client_config'),

  /// `UtcpManual`.
  manual('manual'),

  /// `Tool`.
  tool('tool'),

  /// `CallTemplate`, any `call_template_type`.
  callTemplate('call_template'),

  /// `Auth`, any `auth_type`.
  auth('auth'),

  /// `VariableLoader`, any `variable_loader_type`.
  variableLoader('variable_loader'),

  /// `ToolPostProcessor`, any `tool_post_processor_type`.
  postProcessor('post_processor'),

  /// `ToolRepository`.
  toolRepository('tool_repository'),

  /// `ToolSearchStrategy`.
  toolSearchStrategy('tool_search_strategy');

  const DocumentKind(this.wire);

  /// The spelling in fixture files.
  final String wire;

  /// The kind spelled [wire], or a [FormatException].
  static DocumentKind parse(String wire) =>
      values.where((kind) => kind.wire == wire).firstOrNull ??
      (throw FormatException("Unknown document kind '$wire'."));
}

const _clientConfigKeys = {
  'manual_call_templates',
  'load_variables_from',
  'tool_repository',
  'tool_search_strategy',
  'post_processing',
};

/// The kind of UTCP document [json] is, or `null` when it is not one.
///
/// A v0.1 document (`provider_type`, `tool_provider`) counts as the v1 kind
/// it was renamed to, so the corpus records that Dart rejects it.
DocumentKind? classify(JsonMap json) {
  if (json.keys.any(_clientConfigKeys.contains)) {
    return DocumentKind.clientConfig;
  }
  final tools = json['tools'];
  if (tools is List<Object?> &&
      (json.containsKey('utcp_version') ||
          json.containsKey('manual_version') ||
          tools.any(
            (tool) =>
                tool is Map &&
                (tool.containsKey('tool_call_template') ||
                    tool.containsKey('tool_provider')),
          ))) {
    return DocumentKind.manual;
  }
  if (json.containsKey('name') &&
      (json.containsKey('tool_call_template') ||
          json.containsKey('tool_provider'))) {
    return DocumentKind.tool;
  }
  if (json['call_template_type'] is String || json['provider_type'] is String) {
    return DocumentKind.callTemplate;
  }
  if (json['auth_type'] is String) return DocumentKind.auth;
  if (json['variable_loader_type'] is String) {
    return DocumentKind.variableLoader;
  }
  if (json['tool_post_processor_type'] is String) {
    return DocumentKind.postProcessor;
  }
  if (json['tool_repository_type'] is String) {
    return DocumentKind.toolRepository;
  }
  if (json['tool_search_strategy_type'] is String) {
    return DocumentKind.toolSearchStrategy;
  }
  return null;
}

/// A UTCP document found in a source file.
class Extracted {
  /// Creates a document of [kind] found on [line].
  const Extracted(this.kind, this.document, this.line);

  /// What parses [document].
  final DocumentKind kind;

  /// The document, decoded.
  final JsonMap document;

  /// The 1-based line the document starts on.
  final int line;
}

final _fence = RegExp(r'^(\s*)(`{3,}|~{3,})\s*([\w+-]*)');

/// Every UTCP document in the file at [path] with [contents], outermost
/// first: from fenced code blocks in Markdown, from whole `.json` files,
/// and from object literals in `.py`, `.ts` and `.js` files.
List<Extracted> extractDocuments(String path, String contents) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.md') || lower.endsWith('.mdx')) {
    return _markdown(contents);
  }
  if (lower.endsWith('.json')) return _literals(contents, Syntax.js, 1);
  if (lower.endsWith('.py')) return _literals(contents, Syntax.python, 1);
  if (lower.endsWith('.ts') || lower.endsWith('.js')) {
    return _literals(contents, Syntax.js, 1);
  }
  return const [];
}

List<Extracted> _markdown(String contents) {
  final lines = contents.split('\n');
  final found = <Extracted>[];
  for (var i = 0; i < lines.length; i++) {
    final open = _fence.firstMatch(lines[i]);
    if (open == null) continue;
    final marker = open[2]!;
    final language = open[3]!.toLowerCase();
    final start = i + 1;
    var end = start;
    while (end < lines.length && !lines[end].trimLeft().startsWith(marker)) {
      end++;
    }
    final body = lines.sublist(start, end).join('\n');
    final firstLine = start + 1;
    switch (language) {
      case '' || 'json' || 'jsonc' || 'json5' || 'js' || 'javascript':
      case 'ts' || 'typescript' || 'tsx':
        found.addAll(_literals(body, Syntax.js, firstLine));
      case 'py' || 'python':
        found.addAll(_literals(body, Syntax.python, firstLine));
      case 'yaml' || 'yml':
        found.addAll(_yaml(body, firstLine));
    }
    i = end;
  }
  return found;
}

List<Extracted> _literals(String text, Syntax syntax, int firstLine) => [
  for (final literal in LiteralSource(
    text,
    syntax,
    firstLine: firstLine,
  ).objects((value) => classify(value) != null))
    Extracted(classify(literal.value)!, literal.value, literal.line),
];

List<Extracted> _yaml(String text, int firstLine) {
  final Object? decoded;
  try {
    decoded = decodeYaml(text);
  } on FormatException {
    return const [];
  }
  final found = <Extracted>[];
  void visit(Object? node) {
    switch (node) {
      case final Map<String, Object?> map:
        final kind = classify(map);
        if (kind != null) {
          found.add(Extracted(kind, map, firstLine));
        } else {
          map.values.forEach(visit);
        }
      case final List<Object?> list:
        list.forEach(visit);
    }
  }

  visit(decoded);
  return found;
}
