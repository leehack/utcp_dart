import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:utcp/utcp.dart';
import 'package:yaml/yaml.dart';

import 'file_call_template.dart';

/// Loads UTCP manuals from local files (`file` call templates).
///
/// Discovery reads the manual template's file as a UTCP manual. A tool call
/// returns the text of the tool template's file.
class FileCommunicationProtocol extends CommunicationProtocol {
  /// Relative file paths resolve against [rootDir], or the current
  /// directory when it is null, like the client `root_dir` of the Python and
  /// TypeScript SDKs.
  FileCommunicationProtocol({this.rootDir});

  final String? rootDir;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    FileCallTemplate.type: FileCallTemplate.fromJson,
  };

  /// The absolute path [template] refers to.
  String resolve(FileCallTemplate template) =>
      p.normalize(p.absolute(rootDir ?? p.current, template.filePath));

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<FileCallTemplate>(manualCallTemplate);
    final path = resolve(template);
    RegisterManualResult failure(String error) =>
        RegisterManualResult.failure(template, [error]);
    try {
      final file = File(path);
      if (!await file.exists()) return failure('Manual file not found: $path');
      final content = await file.readAsString();
      final json = asJsonMap(switch (p.extension(path).toLowerCase()) {
        '.yaml' || '.yml' => yamlToJson(loadYaml(content)),
        _ => jsonDecode(content),
      }, 'Manual file');
      if (_isOpenApi(json)) {
        return failure(
          "'$path' is an OpenAPI document; OpenAPI files are not supported "
          'by the file protocol yet.',
        );
      }
      return RegisterManualResult(
        manualCallTemplate: template,
        manual: UtcpManual.fromJson(json),
      );
    } on FormatException catch (e) {
      return failure("Invalid manual file '$path': ${e.message}");
    } on FileSystemException catch (e) {
      return failure("Could not read manual file '$path': ${e.message}");
    }
  }

  /// Returns the content of the tool template's file as text.
  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final path = resolve(
      requireCallTemplate<FileCallTemplate>(toolCallTemplate),
    );
    try {
      return await File(path).readAsString();
    } on FileSystemException catch (e) {
      throw UtcpException(
        "Could not read file '$path' for tool '$toolName': ${e.message}",
      );
    }
  }

  // The reference SDKs convert these with their OpenAPI converter.
  static bool _isOpenApi(JsonMap json) =>
      json.containsKey('openapi') ||
      json.containsKey('swagger') ||
      json.containsKey('paths');
}
