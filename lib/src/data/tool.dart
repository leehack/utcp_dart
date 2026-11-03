import '../json.dart';
import 'call_template.dart';

/// A callable tool described by a UTCP manual.
class Tool {
  const Tool({
    required this.name,
    this.description = '',
    this.inputs = const {},
    this.outputs = const {},
    this.tags = const [],
    this.averageResponseSize,
    required this.toolCallTemplate,
  });

  factory Tool.fromJson(JsonMap json) => Tool(
    name: requiredField<String>(json, 'name'),
    description: optionalField<String>(json, 'description') ?? '',
    inputs: optionalMap(json, 'inputs') ?? const {},
    outputs: optionalMap(json, 'outputs') ?? const {},
    tags: optionalStringList(json, 'tags') ?? const [],
    averageResponseSize: optionalField<num>(json, 'average_response_size')?.toInt(),
    toolCallTemplate: CallTemplate.fromJson(
      asJsonMap(json['tool_call_template'], "Tool '${json['name']}' tool_call_template"),
    ),
  );

  /// Once registered, `manual_name.tool_name`.
  final String name;
  final String description;

  /// JSON Schema of the tool arguments.
  final JsonMap inputs;

  /// JSON Schema of the tool result.
  final JsonMap outputs;
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
    if (averageResponseSize != null) 'average_response_size': averageResponseSize,
    'tool_call_template': toolCallTemplate.toJson(),
  };
}
