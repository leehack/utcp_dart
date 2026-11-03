import 'package:utcp/utcp.dart';

/// An in-memory transport for `fake` call templates that records calls.
class FakeProtocol extends CommunicationProtocol {
  FakeProtocol({
    this.manual = const UtcpManual(tools: []),
    this.errors = const [],
  });

  final UtcpManual manual;
  final List<String> errors;
  final calls = <(String, ToolArguments, FakeCallTemplate)>[];
  bool closed = false;
  int deregistered = 0;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    FakeCallTemplate.type: FakeCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async => errors.isEmpty
      ? RegisterManualResult(
          manualCallTemplate: manualCallTemplate,
          manual: manual,
        )
      : RegisterManualResult.failure(manualCallTemplate, errors);

  @override
  Future<void> deregisterManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async => deregistered++;

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final template = requireCallTemplate<FakeCallTemplate>(toolCallTemplate);
    calls.add((toolName, arguments, template));
    return {'tool': toolName, 'token': template.token, ...arguments};
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeCallTemplate extends CallTemplate {
  const FakeCallTemplate({
    super.name,
    this.token,
    super.allowedCommunicationProtocols,
  });

  factory FakeCallTemplate.fromJson(JsonMap json) => FakeCallTemplate(
    name: json.optString('name'),
    token: json.optString('token'),
    allowedCommunicationProtocols: json.allowedCommunicationProtocols,
  );

  static const type = 'fake';

  final String? token;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {'token': ?token};
}

Tool fakeTool(
  String name, {
  String? token,
  List<String> tags = const [],
  String description = '',
}) => Tool(
  name: name,
  description: description,
  tags: tags,
  toolCallTemplate: FakeCallTemplate(token: token),
);
