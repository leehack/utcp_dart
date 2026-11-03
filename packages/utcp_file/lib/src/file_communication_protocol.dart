import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:utcp/utcp.dart';

import 'dotenv.dart';
import 'file_call_template.dart';

/// Loads UTCP manuals from local files (`file` call templates).
///
/// Discovery reads the manual template's file as a UTCP manual. A tool call
/// returns the text of the tool template's file.
class FileCommunicationProtocol extends CommunicationProtocol {
  /// Relative file paths resolve against [rootDir], else the calling
  /// client's [UtcpClient.rootDir], else the current directory, like the
  /// client `root_dir` of the Python and TypeScript SDKs.
  ///
  /// Also registers [DotEnvVariableLoader], so `load_variables_from` entries
  /// of type `dotenv` parse, as the Python SDK does in its core.
  FileCommunicationProtocol({
    this.rootDir,
    this.maxFileBytes = 10 * 1024 * 1024,
  }) {
    DotEnvVariableLoader.register();
  }

  /// Directory relative file paths resolve against, before the client's
  /// [UtcpClient.rootDir].
  final String? rootDir;

  /// Largest file, in bytes, that discovery or a tool call reads; a larger
  /// file fails. The reference SDKs have no limit.
  final int maxFileBytes;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    FileCallTemplate.type: FileCallTemplate.fromJson,
  };

  /// The absolute path [template] refers to, for a call from [caller].
  ///
  /// `..` segments are kept for the OS to resolve, so `link/..` is the
  /// parent of the symlink's target, as in Python, not [rootDir].
  String resolve(FileCallTemplate template, {UtcpClient? caller}) =>
      p.absolute(rootDir ?? caller?.rootDir ?? p.current, template.filePath);

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<FileCallTemplate>(manualCallTemplate);
    final path = resolve(template, caller: caller);
    RegisterManualResult failure(String error) =>
        RegisterManualResult.failure(template, [error]);
    try {
      final file = File(path);
      if (!await file.exists()) return failure('Manual file not found: $path');
      final content = await _read(path);
      final json = asJsonMap(switch (p.extension(path).toLowerCase()) {
        '.yaml' || '.yml' => decodeYaml(content),
        _ => jsonDecode(content),
      }, 'Manual file');
      // As in the Python SDK, a file counts as a remote origin: neither an
      // OpenAPI document nor a UTCP manual in it may point tools at loopback.
      final source = Uri.file(path);
      final UtcpManual manual;
      if (OpenApiConverter.isOpenApi(json)) {
        manual = OpenApiConverter(
          json,
          specUrl: source,
          callTemplateName: template.name,
          authTools: template.authTools,
        ).convert();
      } else {
        manual = UtcpManual.fromJson(json);
        rejectRemoteLoopbackToolUrls(source, manual, 'manual discovery');
      }
      return RegisterManualResult(manualCallTemplate: template, manual: manual);
    } on FormatException catch (e) {
      return failure("Invalid manual file '$path': ${e.message}");
    } on UtcpException catch (e) {
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
      caller: caller,
    );
    try {
      return await _read(path);
    } on FileSystemException catch (e) {
      throw UtcpException(
        "Could not read file '$path' for tool '$toolName': ${e.message}",
      );
    }
  }

  /// The UTF-8 text of the file at [path], read only up to [maxFileBytes].
  Future<String> _read(String path) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in File(path).openRead(0, maxFileBytes + 1)) {
      bytes.add(chunk);
    }
    if (bytes.length > maxFileBytes) {
      throw FileSystemException(
        'File is larger than the limit of $maxFileBytes bytes',
        path,
      );
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw FileSystemException('File is not valid UTF-8 text', path);
    }
  }
}
