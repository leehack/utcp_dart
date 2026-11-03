import '../json.dart';
import 'call_template.dart';
import 'tool.dart';

/// The UTCP specification version this package implements, written as
/// `utcp_version` into the manuals it creates. Every default in the package
/// reads it from here.
const utcpProtocolVersion = '1.1.0';

/// The document a provider returns during discovery.
class UtcpManual {
  const UtcpManual({
    this.utcpVersion = utcpProtocolVersion,
    this.manualVersion = '1.0.0',
    required this.tools,
  });

  factory UtcpManual.fromJson(JsonMap json) => UtcpManual(
    utcpVersion: json.optString('utcp_version') ?? utcpProtocolVersion,
    manualVersion: json.optString('manual_version') ?? '1.0.0',
    tools: [for (final tool in json.objectList('tools')) Tool.fromJson(tool)],
  );

  /// Whether [json] looks like a UTCP manual rather than, for example, an
  /// OpenAPI document.
  static bool isManual(JsonMap json) =>
      json['utcp_version'] != null && json['tools'] is List<Object?>;

  final String utcpVersion;
  final String manualVersion;
  final List<Tool> tools;

  JsonMap toJson() => {
    'utcp_version': utcpVersion,
    'manual_version': manualVersion,
    'tools': [for (final tool in tools) tool.toJson()],
  };
}

class RegisterManualResult {
  const RegisterManualResult({
    required this.manualCallTemplate,
    required this.manual,
    this.errors = const [],
  });

  const RegisterManualResult.failure(this.manualCallTemplate, this.errors)
    : manual = const UtcpManual(tools: []);

  final CallTemplate manualCallTemplate;
  final UtcpManual manual;
  final List<String> errors;

  bool get success => errors.isEmpty;
}
