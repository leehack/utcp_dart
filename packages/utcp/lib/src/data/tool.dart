import '../json.dart';
import 'call_template.dart';
import 'json_schema.dart';

/// Arguments for a tool call, matching the tool's [Tool.inputs] schema.
typedef ToolArguments = Map<String, Object?>;

/// A callable tool described by a UTCP manual.
class Tool {
  const Tool({
    required this.name,
    this.description = '',
    this.inputs = JsonSchema.empty,
    this.outputs = JsonSchema.empty,
    this.tags = const [],
    this.averageResponseSize,
    required this.toolCallTemplate,
  });

  factory Tool.fromJson(JsonMap json) {
    final name = json.string('name');
    return Tool(
      name: name,
      description: json.optString('description') ?? '',
      inputs: JsonSchema(json.optObject('inputs') ?? const {}),
      outputs: JsonSchema(json.optObject('outputs') ?? const {}),
      tags: json.optStringList('tags') ?? const [],
      averageResponseSize: json.optInt('average_response_size'),
      toolCallTemplate: CallTemplate.fromJson(
        json.object('tool_call_template'),
      ),
    );
  }

  /// Once registered, `manual_name.tool_name`.
  final String name;
  final String description;
  final JsonSchema inputs;
  final JsonSchema outputs;
  final List<String> tags;

  /// Typical response size in bytes, if the provider declares one.
  final int? averageResponseSize;
  final CallTemplate toolCallTemplate;

  Tool copyWith({String? name, CallTemplate? toolCallTemplate}) => Tool(
    name: name ?? this.name,
    description: description,
    inputs: inputs,
    outputs: outputs,
    tags: tags,
    averageResponseSize: averageResponseSize,
    toolCallTemplate: toolCallTemplate ?? this.toolCallTemplate,
  );

  JsonMap toJson() => {
    'name': name,
    'description': description,
    'inputs': inputs,
    'outputs': outputs,
    'tags': tags,
    'average_response_size': ?averageResponseSize,
    'tool_call_template': toolCallTemplate.toJson(),
  };
}
