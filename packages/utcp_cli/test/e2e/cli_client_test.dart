@Tags(['e2e'])
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';

void main() {
  late Directory temp;
  late UtcpClient client;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('utcp_cli_e2e_');
    await File('${temp.path}/manual.json').writeAsString(
      jsonEncode({
        'utcp_version': '1.0.1',
        'tools': [
          {
            'name': 'echo',
            'tags': ['text'],
            'tool_call_template': {
              'call_template_type': 'cli',
              'commands': [
                {'command': 'echo UTCP_ARG_message_UTCP_END'},
              ],
            },
          },
          {
            'name': 'whereami',
            'tool_call_template': {
              'call_template_type': 'cli',
              'commands': [
                {'command': 'cd UTCP_ARG_dir_UTCP_END'},
                {
                  'command':
                      r'''printf '{"cwd": "%s", "token": "%s"}' "$(pwd)" "$(printenv TOKEN)"''',
                },
              ],
              'env_vars': {'TOKEN': r'${TOKEN}'},
            },
          },
          {
            'name': 'previous_output',
            'tool_call_template': {
              'call_template_type': 'cli',
              'commands': [
                {'command': 'echo first'},
                {'command': r'echo "got $CMD_0_OUTPUT"'},
              ],
            },
          },
        ],
      }),
    );
    client = await UtcpClient.fromJson(
      {
        'variables': {'local_TOKEN': 'secret-from-config'},
        'manual_call_templates': [
          {
            'name': 'local',
            'call_template_type': 'cli',
            'commands': [
              {'command': 'cat manual.json'},
            ],
            'working_dir': temp.path,
          },
        ],
      },
      protocols: [CliCommunicationProtocol()],
    );
  });

  tearDown(() async {
    await client.close();
    await temp.delete(recursive: true);
  });

  test('tools discovered from a command are called end to end', () async {
    expect((await client.getTools()).map((t) => t.name), [
      'local.echo',
      'local.whereami',
      'local.previous_output',
    ]);
    expect(
      await client.callTool('local.echo', {'message': 'a; echo b'}),
      'a; echo b',
    );
    expect(
      await client.callToolStreaming('local.echo', {'message': 'hi'}).toList(),
      ['hi'],
    );
    final dir = await temp.resolveSymbolicLinks();
    expect(await client.callTool('local.whereami', {'dir': dir}), {
      'cwd': dir,
      'token': 'secret-from-config',
    });
  });

  // UtcpClient substitutes `$NAME` in the whole call template before the
  // protocol runs, as the Python and TypeScript clients do, so a spec-style
  // `$CMD_0_OUTPUT` reference only works when called through the protocol
  // directly. Fixing this needs a change in the core substitutor.
  test(r'$CMD_<i>_OUTPUT is taken as a client variable', () async {
    await expectLater(
      client.callTool('local.previous_output'),
      throwsA(isA<UtcpVariableNotFoundException>()),
    );
  });

  test('the example runs', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_cli_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Found shell.greet'));
    expect(result.stdout, contains(r'Hello, World; rm -rf $HOME!'));
    expect(result.stdout, contains('{files: 1}'));
  });
}
