import '../data/auth.dart';
import '../data/call_template.dart';
import '../json.dart';

/// A UTCP manual or OpenAPI document supplied inline, as JSON or YAML.
///
/// Used as a tool's call template, calling the tool returns [content].
class TextCallTemplate extends CallTemplate {
  const TextCallTemplate({
    super.name,
    required this.content,
    this.baseUrl,
    this.authTools,
    super.allowedCommunicationProtocols,
  });

  factory TextCallTemplate.fromJson(JsonMap json) {
    if (json.containsKey('file_path')) {
      throw const FormatException(
        "Text call templates no longer support 'file_path'; put the document "
        "in 'content', or use a 'file' call template.",
      );
    }
    if (json['auth'] != null) {
      throw const FormatException(
        "Text call templates do not support 'auth'; use 'auth_tools' for the "
        'tools generated from an OpenAPI document.',
      );
    }
    return TextCallTemplate(
      name: json.optString('name'),
      content: json.string('content'),
      baseUrl: json.optString('base_url'),
      authTools: json.optAuth('auth_tools'),
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'text';

  /// The UTCP manual or OpenAPI document, as JSON or YAML.
  final String content;

  /// Base URL of the tools converted from an OpenAPI document, replacing
  /// its servers.
  final String? baseUrl;

  /// Auth applied to the tools converted from an OpenAPI document.
  final Auth? authTools;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    'content': content,
    'base_url': ?baseUrl,
    'auth_tools': ?authTools?.toJson(),
  };
}
