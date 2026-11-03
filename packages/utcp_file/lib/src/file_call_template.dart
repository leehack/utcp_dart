import 'package:utcp/utcp.dart';

/// A UTCP manual, or a tool's content, in a local JSON or YAML file.
class FileCallTemplate extends CallTemplate {
  const FileCallTemplate({
    super.name,
    required this.filePath,
    this.authTools,
    super.allowedCommunicationProtocols,
  });

  factory FileCallTemplate.fromJson(JsonMap json) {
    if (json['auth'] != null) {
      throw const FormatException('file call templates do not support auth.');
    }
    return FileCallTemplate(
      name: json.optString('name'),
      filePath: json.string('file_path'),
      authTools: json.optAuth('auth_tools'),
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'file';

  /// Absolute, or relative to the protocol's root directory. Files ending
  /// in `.yaml` or `.yml` are read as YAML, everything else as JSON.
  final String filePath;

  /// Auth for the tools generated from an OpenAPI document in the file.
  final Auth? authTools;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    'file_path': filePath,
    'auth_tools': ?authTools?.toJson(),
  };
}
