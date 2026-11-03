import '../json.dart';
import 'call_template.dart';
import 'tool.dart';

/// UTCP protocol version written into manuals created by this package.
const utcpProtocolVersion = '1.0.1';

/// The document a provider returns during discovery.
class UtcpManual {
  const UtcpManual({
    this.utcpVersion = utcpProtocolVersion,
    this.manualVersion = '1.0.0',
    required this.tools,
  });

  factory UtcpManual.fromJson(JsonMap json) => UtcpManual(
    utcpVersion: optionalField<String>(json, 'utcp_version') ?? utcpProtocolVersion,
    manualVersion: optionalField<String>(json, 'manual_version') ?? '1.0.0',
    tools: [
      for (final (i, tool) in (requiredField<List>(json, 'tools')).indexed)
        Tool.fromJson(asJsonMap(tool, 'tools[$i]')),
    ],
  );

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
    required this.success,
    this.errors = const [],
  });

  final CallTemplate manualCallTemplate;
  final UtcpManual manual;
  final bool success;
  final List<String> errors;
}
