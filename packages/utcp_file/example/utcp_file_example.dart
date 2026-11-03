import 'dart:io';

import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

/// Loads a YAML manual from disk, with file names taken from a `.env` file,
/// and calls a tool that returns a file's content.
Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('utcp_file_example_');
  await File('${dir.path}/manual.yaml').writeAsString(r'''
utcp_version: "1.0.1"
tools:
  - name: release_notes
    description: The latest release notes
    tags: [docs]
    tool_call_template:
      call_template_type: file
      file_path: ${NOTES_FILE}
''');
  await File(
    '${dir.path}/notes.md',
  ).writeAsString('# 1.0.0\n\n- First release\n');
  // Variables are namespaced by manual name: ${NOTES_FILE} in manual "docs"
  // resolves docs_NOTES_FILE.
  await File('${dir.path}/.env').writeAsString('''
# Paths are relative to the protocol's root directory.
export docs_MANUAL_FILE=manual.yaml
docs_NOTES_FILE="notes.md"
''');

  final client = await UtcpClient.fromJson(
    {
      'load_variables_from': [
        {'variable_loader_type': 'dotenv', 'env_file_path': '${dir.path}/.env'},
      ],
      'manual_call_templates': [
        {
          'name': 'docs',
          'call_template_type': 'file',
          'file_path': r'${MANUAL_FILE}',
        },
      ],
    },
    protocols: [FileCommunicationProtocol(rootDir: dir.path)],
  );
  try {
    final tool = (await client.searchTools('release notes')).first;
    print('Found ${tool.name}: ${tool.description}');
    print(await client.callTool(tool.name));
  } finally {
    await client.close();
    await dir.delete(recursive: true);
  }
}
