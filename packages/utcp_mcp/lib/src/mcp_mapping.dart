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
      inputs: JsonSchema(mcpTool.optObject('inputSchema') ?? const {}),
      outputs: JsonSchema(mcpTool.optObject('outputSchema') ?? const {}),
      toolCallTemplate: template,
    );

/// A UTCP tool that reads the MCP resource [resource] (`resources/list`
/// JSON) of [serverName].
Tool toolFromMcpResource(
  JsonMap resource,
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
    name: _toolName(template, serverName, '$resourceToolPrefix$name'),
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
