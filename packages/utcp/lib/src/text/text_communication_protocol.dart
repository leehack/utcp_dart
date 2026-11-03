import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import '../client.dart';
import '../communication_protocol.dart';
import '../data/call_template.dart';
import '../data/tool.dart';
import '../data/utcp_manual.dart';
import '../exceptions.dart';
import '../http/openapi_converter.dart';
import '../json.dart';
import '../registry.dart';
import 'text_call_template.dart';

final _log = Logger('utcp.text');

/// The `text` transport: manuals supplied inline, with no I/O, so it runs on
/// every platform.
///
/// An OpenAPI document is converted with [OpenApiConverter] as if it came
/// from a remote origin (`text://content`), so its tools may only target
/// loopback when [TextCallTemplate.baseUrl] says so.
class TextCommunicationProtocol extends CommunicationProtocol {
  static final _specUrl = Uri.parse('text://content');

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    TextCallTemplate.type: TextCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<TextCallTemplate>(manualCallTemplate);
    try {
      final document = asJsonMap(_parse(template.content), 'Text content');
      final manual = OpenApiConverter.isOpenApi(document)
          ? OpenApiConverter(
              document,
              specUrl: _specUrl,
              callTemplateName: template.name,
              authTools: template.authTools,
              baseUrl: template.baseUrl,
            ).convert()
          : UtcpManual.fromJson(document);
      return RegisterManualResult(manualCallTemplate: template, manual: manual);
    } on Exception catch (e) {
      final reason = switch (e) {
        UtcpException(:final message) => message,
        FormatException(:final message) => message,
        _ => '$e',
      };
      final message = 'Failed to register text manual: $reason';
      _log.warning(message);
      return RegisterManualResult.failure(template, [message]);
    }
  }

  static Object? _parse(String content) {
    try {
      return jsonDecode(content);
    } on FormatException catch (jsonError) {
      try {
        return decodeYaml(content);
      } on YamlException {
        throw FormatException(
          'Failed to parse content as JSON or YAML: ${jsonError.message}',
        );
      }
    }
  }

  /// Returns the template's content unchanged.
  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async => requireCallTemplate<TextCallTemplate>(toolCallTemplate).content;
}
