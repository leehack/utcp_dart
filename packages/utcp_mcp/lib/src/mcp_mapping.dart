import 'dart:convert';

import 'package:utcp/utcp.dart';

/// Prefix of the tools that read a resource when `register_resources_as_tools`
/// is set.
const resourceToolPrefix = 'resource_';

/// A UTCP tool for the MCP tool [mcpTool] (`tools/list` JSON) of [serverName].
Tool toolFromMcp(JsonMap mcpTool, String serverName, CallTemplate template) =>
    Tool(
      name: _toolName(template, serverName, mcpTool.string('name')),
      description: mcpTool.optString('description') ?? '',
      inputs: JsonSchema(inlineSchemaRefs(mcpTool.optObject('inputSchema'))),
      outputs: JsonSchema(inlineSchemaRefs(mcpTool.optObject('outputSchema'))),
      toolCallTemplate: template,
    );

/// Bounds the nodes produced while inlining one schema, so references that
/// fan out cannot expand it exponentially.
const _maxInlinedNodes = 10000;

/// Keywords whose values are data, not schemas, so a `$ref` key in them is
/// left alone.
const _dataKeywords = {'const', 'default', 'enum', 'example', 'examples'};

/// Keywords whose values map names to schemas, so their keys are names, not
/// keywords: a property may be called `default` or `$ref`.
const _namedSchemaKeywords = {
  'properties',
  'patternProperties',
  'dependentSchemas',
  'dependencies',
  r'$defs',
  'definitions',
};

/// [schema] with its local `$ref`s inlined, as the TypeScript SDK does, since
/// many clients ignore the `$defs` that FastMCP and Pydantic emit. Keywords
/// next to a `$ref` are merged over its target. A cyclic, remote or
/// unresolvable reference stays in place, and then so do the root `$defs`
/// and `definitions`, as written; otherwise they are dropped once inlined. A
/// schema that would grow past [_maxInlinedNodes] nodes is returned as is.
JsonMap inlineSchemaRefs(JsonMap? schema) {
  if (schema == null) return const {};
  final inliner = _RefInliner(schema);
  final Object? inlined;
  try {
    inlined = inliner.inline(schema, const {'#'});
  } on _TooLarge {
    return schema;
  }
  final result = asJsonMap(inlined, 'Tool schema');
  for (final key in const [r'$defs', 'definitions']) {
    if (!schema.containsKey(key) || !inliner.inlined) continue;
    if (inliner.leftInPlace) {
      result[key] = schema[key];
    } else {
      result.remove(key);
    }
  }
  return result;
}

final class _TooLarge implements Exception {}

final class _RefInliner {
  _RefInliner(this.root);

  final JsonMap root;
  int _nodes = 0;

  /// Whether any reference was inlined.
  bool inlined = false;

  /// Whether any reference was left in place.
  bool leftInPlace = false;

  /// A copy of [node] with local references inlined. [resolving] holds the
  /// references being expanded above [node]; meeting one again is a cycle.
  /// When [named], [node] maps names to schemas.
  Object? inline(Object? node, Set<String> resolving, {bool named = false}) {
    if (node is! Map<Object?, Object?> && node is! List<Object?>) return node;
    if (++_nodes > _maxInlinedNodes) throw _TooLarge();
    if (node is List<Object?>) {
      return [for (final item in node) inline(item, resolving)];
    }
    final map = asJsonMap(node, 'Tool schema');
    if (named) {
      return {
        for (final MapEntry(:key, :value) in map.entries)
          key: inline(value, resolving),
      };
    }
    final ref = map[r'$ref'];
    final siblings = <String, Object?>{
      for (final MapEntry(:key, :value) in map.entries)
        if (key != r'$ref' || ref is! String)
          key: _dataKeywords.contains(key)
              ? value
              : inline(
                  value,
                  resolving,
                  named: _namedSchemaKeywords.contains(key),
                ),
    };
    if (ref is! String) return siblings;
    final target = resolving.contains(ref) ? null : _pointer(ref);
    if (target is! Map<Object?, Object?>) {
      leftInPlace = true;
      return {r'$ref': ref, ...siblings};
    }
    inlined = true;
    return {
      ...asJsonMap(inline(target, {...resolving, ref}), 'Tool schema'),
      ...siblings,
    };
  }

  /// The value at the local JSON pointer [ref] (`#` or `#/...`), or null.
  Object? _pointer(String ref) {
    if (ref != '#' && !ref.startsWith('#/')) return null;
    Object? node = root;
    for (final raw
        in ref.length == 1 ? const <String>[] : ref.substring(2).split('/')) {
      final String part;
      try {
        part = Uri.decodeComponent(
          raw,
        ).replaceAll('~1', '/').replaceAll('~0', '~');
      } on ArgumentError {
        return null;
      } on FormatException {
        return null;
      }
      node = switch (node) {
        Map<Object?, Object?>() => node[part],
        List<Object?>() => switch (int.tryParse(part)) {
          final i? when i >= 0 && i < node.length => node[i],
          _ => null,
        },
        _ => null,
      };
      if (node == null) return null;
    }
    return node;
  }
}

/// The resource tools of one server: each resource (`resources/list` JSON)
/// by its tool name, without the manual and server prefix.
///
/// A resource's tool is `resource_<name>` when no other resource or tool of
/// [toolNames] has that name. Otherwise every resource sharing it becomes
/// `resource_<name>_<n>`, numbered from 1 in URI order, skipping taken
/// names, so tools keep their names and each name reads one URI. A URI
/// listed twice counts once.
Map<String, JsonMap> resourceTools(
  List<JsonMap> resources,
  Set<String> toolNames,
) {
  final byUri = <String, JsonMap>{};
  for (final resource in resources) {
    byUri.putIfAbsent(resource.string('uri'), () => resource);
  }
  final groups = <String, List<JsonMap>>{};
  for (final uri in byUri.keys.toList()..sort()) {
    final resource = byUri[uri]!;
    (groups['$resourceToolPrefix${resource.string('name')}'] ??= []).add(
      resource,
    );
  }
  final bases = groups.keys.toList()..sort();
  final named = <String, JsonMap>{};
  final taken = {...toolNames};
  final suffixed = <String>[];
  for (final base in bases) {
    final group = groups[base]!;
    if (group.length == 1 && taken.add(base)) {
      named[base] = group.single;
    } else {
      suffixed.add(base);
    }
  }
  for (final base in suffixed) {
    var n = 1;
    for (final resource in groups[base]!) {
      while (!taken.add('${base}_$n')) {
        n++;
      }
      named['${base}_$n'] = resource;
    }
  }
  return named;
}

/// A UTCP tool named [toolName] (see [resourceTools]) that reads the MCP
/// resource [resource] (`resources/list` JSON) of [serverName].
Tool toolFromMcpResource(
  JsonMap resource,
  String toolName,
  String serverName,
  CallTemplate template,
) {
  final name = resource.string('name');
  final uri = resource.string('uri');
  final description = switch (resource.optString('description')) {
    null || '' => name,
    final text => text,
  };
  return Tool(
    name: _toolName(template, serverName, toolName),
    description: 'Read resource: $description. URI: $uri',
    inputs: const JsonSchema({
      'type': 'object',
      'properties': <String, Object?>{},
      'required': <Object?>[],
    }),
    outputs: const JsonSchema({
      'type': 'object',
      'properties': {
        'contents': {'type': 'array', 'description': 'Resource contents'},
      },
    }),
    toolCallTemplate: template,
  );
}

String _toolName(CallTemplate template, String serverName, String name) =>
    switch (template.name) {
      null => '$serverName.$name',
      final manual => '$manual.$serverName.$name',
    };

/// Maps a `tools/call` result (JSON) to a plain value.
///
/// `structuredContent` wins when present, with the FastMCP `{"result": x}`
/// wrapper around non-object values removed. Otherwise each content item is
/// mapped: text is parsed as JSON, then as a number, and kept as a string
/// when neither applies; other items are returned as their JSON. A single
/// item is returned on its own. `isError` results are returned the same way,
/// as the reference SDKs do, so the caller sees the server's error text.
Object? toolResultValue(JsonMap result) {
  if (result['structuredContent'] case final Object structured) {
    return _unwrapStructured(structured);
  }
  if (result['structured_output'] case final Object legacy) return legacy;
  final content = result.optList('content');
  if (content == null) return result;
  final values = [
    for (final (i, item) in content.indexed)
      _contentValue(asJsonMap(item, "Field 'content[$i]'")),
  ];
  return values.length == 1 ? values.single : values;
}

Object? _unwrapStructured(Object structured) {
  if (structured is Map && structured.length == 1) {
    final inner = structured['result'];
    if (structured.containsKey('result') && inner is! Map) return inner;
  }
  return structured;
}

Object? _contentValue(JsonMap item) {
  final text = item['text'];
  return item['type'] == 'text' && text is String
      ? parseTextContent(text)
      : item;
}

/// Parses MCP text content: JSON, then a finite number, else the text itself.
Object? parseTextContent(String text) {
  if (text.trim().isEmpty) return text;
  try {
    return jsonDecode(text);
  } on FormatException {
    final number = num.tryParse(text.trim());
    return number != null && number.isFinite ? number : text;
  }
}
