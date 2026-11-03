@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('utcp_file_e2e_');
    await File('${temp.path}/manuals/tools.json').create(recursive: true);
    await File('${temp.path}/manuals/tools.json').writeAsString('''
{
  "utcp_version": "1.0.1",
  "tools": [
    {
      "name": "readme",
      "description": "Project readme",
      "tags": ["docs"],
      "tool_call_template": {
        "call_template_type": "file",
        "file_path": "\${README}"
      }
    }
  ]
}
''');
    await File('${temp.path}/README.txt').writeAsString('Read me first.');
    await File('${temp.path}/.env').writeAsString('''
# Variables for manual "local"
export local_MANUAL='manuals/tools.json'
local_README=README.txt # inline comment
''');
  });

  tearDown(() => temp.delete(recursive: true));

  test('a file manual with dotenv variables works end to end', () async {
    DotEnvVariableLoader.register();
    final client = await UtcpClient.fromJson(
      {
        'load_variables_from': [
          {
            'variable_loader_type': 'dotenv',
            'env_file_path': '${temp.path}/.env',
          },
        ],
        'manual_call_templates': [
          {
            'name': 'local',
            'call_template_type': 'file',
            'file_path': r'${MANUAL}',
          },
        ],
      },
      protocols: [FileCommunicationProtocol(rootDir: temp.path)],
    );
    addTearDown(client.close);
    expect((await client.getTools()).map((t) => t.name), ['local.readme']);
    expect(await client.callTool('local.readme'), 'Read me first.');
    expect(await client.callToolStreaming('local.readme').toList(), [
      'Read me first.',
    ]);
  });

  test('OpenAPI tools register only when http is allowed', () async {
    await File('${temp.path}/openapi.json').writeAsString('''
{
  "openapi": "3.0.0",
  "servers": [{"url": "https://pets.example.com"}],
  "paths": {"/pets": {"get": {"operationId": "listPets"}}}
}
''');
    Future<List<String>> tools(List<String>? allowed) async {
      final client = await UtcpClient.fromJson(
        {
          'manual_call_templates': [
            {
              'name': 'pets',
              'call_template_type': 'file',
              'file_path': 'openapi.json',
              'allowed_communication_protocols': ?allowed,
            },
          ],
        },
        protocols: [FileCommunicationProtocol(rootDir: temp.path)],
      );
      addTearDown(client.close);
      return [for (final tool in await client.getTools()) tool.name];
    }

    expect(await tools(null), isEmpty);
    expect(await tools(['file', 'http']), ['pets.listPets']);
  });

  test('a failed file manual leaves the client usable', () async {
    final client = await UtcpClient.fromJson(
      {
        'manual_call_templates': [
          {
            'name': 'missing',
            'call_template_type': 'file',
            'file_path': 'nope.json',
          },
        ],
      },
      protocols: [FileCommunicationProtocol(rootDir: temp.path)],
    );
    addTearDown(client.close);
    expect(await client.getTools(), isEmpty);
  });

  test('the example runs', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_file_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Found docs.release_notes'));
    expect(result.stdout, contains('- First release'));
  });
}
