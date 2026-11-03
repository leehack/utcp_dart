import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';

/// Discovers tools from a command that prints a UTCP manual, then calls
/// them. Runs on macOS and Linux (bash).
Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('utcp_cli_example_');
  await File('${dir.path}/manual.json').writeAsString(
    jsonEncode({
      'utcp_version': '1.0.1',
      'tools': [
        {
          'name': 'greet',
          'description': 'Greets someone',
          'inputs': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
          },
          'tool_call_template': {
            'call_template_type': 'cli',
            'commands': [
              {'command': 'echo "Hello, UTCP_ARG_name_UTCP_END!"'},
            ],
          },
        },
        {
          'name': 'file_info',
          'description': 'Lists a directory as JSON',
          'tool_call_template': {
            'call_template_type': 'cli',
            'commands': [
              {'command': 'cd UTCP_ARG_dir_UTCP_END'},
              {'command': r'''printf '{"files": %s}' "$(ls | wc -l)"'''},
            ],
          },
        },
      ],
    }),
  );

  final client = await UtcpClient.create(
    config: UtcpClientConfig(
      manualCallTemplates: [
        CliCallTemplate(
          name: 'shell',
          commands: [const CommandStep('cat manual.json')],
          workingDir: dir.path,
        ),
      ],
    ),
    protocols: [CliCommunicationProtocol()],
  );
  try {
    for (final tool in await client.getTools()) {
      print('Found ${tool.name}: ${tool.description}');
    }
    // The argument reaches the command as data, never as shell syntax.
    print(
      await client.callTool('shell.greet', {'name': r'World; rm -rf $HOME'}),
    );
    print(await client.callTool('shell.file_info', {'dir': dir.path}));
  } finally {
    await client.close();
    await dir.delete(recursive: true);
  }
}
