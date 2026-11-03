@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';

import '../support/processes.dart';

void main() {
  late UtcpClient client;
  late CliCommunicationProtocol protocol;
  late Directory temp;

  setUpAll(
    () async => client = await UtcpClient.create(
      protocols: [CliCommunicationProtocol()],
    ),
  );
  tearDownAll(() => client.close());

  setUp(() async {
    protocol = CliCommunicationProtocol(
      discoveryTimeout: const Duration(seconds: 10),
      callTimeout: const Duration(seconds: 10),
    );
    temp = await Directory.systemTemp.createTemp('utcp_cli_test_');
  });

  tearDown(() async {
    await protocol.close();
    await temp.delete(recursive: true);
  });

  Future<Object?> call(
    List<CommandStep> commands, {
    ToolArguments arguments = const {},
    Map<String, String>? envVars,
    List<String>? inheritEnvVars,
    String? workingDir,
  }) => protocol.callTool(
    client,
    'test.tool',
    arguments,
    CliCallTemplate(
      commands: commands,
      envVars: envVars,
      inheritEnvVars: inheritEnvVars,
      workingDir: workingDir,
    ),
  );

  group('commands', () {
    test('only the last output is returned by default', () async {
      expect(
        await call([
          const CommandStep('echo "Step 1"'),
          const CommandStep('echo "Step 2"'),
        ]),
        'Step 2',
      );
    });

    test('append_to_final_output selects the outputs', () async {
      expect(
        await call([
          const CommandStep('echo First', appendToFinalOutput: true),
          const CommandStep('echo Second', appendToFinalOutput: false),
          const CommandStep('echo Third', appendToFinalOutput: true),
        ]),
        'First\nThird',
      );
    });

    test(
      'a later command reads an earlier output as \$CMD_<i>_OUTPUT',
      () async {
        expect(
          await call(
            [
              const CommandStep(
                'echo "Initial message: UTCP_ARG_message_UTCP_END"',
              ),
              const CommandStep(r'echo "Received: $CMD_0_OUTPUT"'),
            ],
            arguments: {'message': 'Workflow Argument'},
          ),
          'Received: Initial message: Workflow Argument',
        );
      },
    );

    test('cd and variables persist between commands', () async {
      final dir = await temp.resolveSymbolicLinks();
      expect(
        await call([
          CommandStep("cd '$dir'"),
          const CommandStep('GREETING=hi'),
          const CommandStep(r'echo "$GREETING from $(pwd)"'),
        ]),
        'hi from $dir',
      );
    });

    test(r'$? still reports the previous command', () async {
      expect(
        await call([const CommandStep('false'), const CommandStep(r'echo $?')]),
        '1',
      );
    });

    test('an output that looks like an echo flag is printed as is', () async {
      expect(await call([const CommandStep("printf '%s' -n")]), '-n');
    });

    test('an empty command is allowed', () async {
      expect(
        await call([
          const CommandStep(''),
          const CommandStep(r'echo "<$CMD_0_OUTPUT>"'),
        ]),
        '<>',
      );
    });

    test('JSON output is decoded', () async {
      expect(
        await call([
          const CommandStep(r'''echo '{"ok": true, "n": [1, 2]}' '''),
        ]),
        {
          'ok': true,
          'n': [1, 2],
        },
      );
      expect(await call([const CommandStep("echo '{not json'")]), '{not json');
    });

    test('a failing command returns its error text', () async {
      final result = await call([const CommandStep('ls /definitely/not/here')]);
      expect(result, isA<String>());
      expect('$result', contains('/definitely/not/here'));
    });

    test('a script syntax error returns the shell error', () async {
      expect(
        '${await call([const CommandStep('echo "unterminated')])}',
        contains('unexpected EOF'),
      );
    });

    test('non-string arguments are passed as JSON', () async {
      expect(
        await call(
          [const CommandStep('echo UTCP_ARG_n_UTCP_END UTCP_ARG_o_UTCP_END')],
          arguments: {
            'n': 3,
            'o': {'a': true},
          },
        ),
        '3 {"a":true}',
      );
    });

    test('a missing argument fails the call', () async {
      await expectLater(
        call([const CommandStep('echo UTCP_ARG_name_UTCP_END')]),
        throwsA(isA<UtcpException>()),
      );
    });
  });

  group('injection', () {
    File canary() => File('${temp.path}/pwned');

    for (final (context, command, payload) in [
      ('bare', 'echo UTCP_ARG_v_UTCP_END', 'benign; touch "\$CANARY"'),
      (
        'double quotes',
        'echo "URL=UTCP_ARG_v_UTCP_END"',
        '"; touch "\$CANARY"; "',
      ),
      (
        'single quotes',
        "echo 'URL=UTCP_ARG_v_UTCP_END end'",
        "'; touch \"\$CANARY\"; '",
      ),
      (
        'command substitution',
        'echo UTCP_ARG_v_UTCP_END',
        r'$(touch "$CANARY")',
      ),
      ('backticks', 'echo "UTCP_ARG_v_UTCP_END"', r'`touch "$CANARY"`'),
      ('newline', 'echo UTCP_ARG_v_UTCP_END', 'a\ntouch "\$CANARY"'),
    ]) {
      test('an argument in $context is never run', () async {
        final result = await call(
          [CommandStep(command)],
          arguments: {'v': payload},
          envVars: {'CANARY': canary().path},
        );
        expect(canary().existsSync(), isFalse);
        expect('$result', contains(payload.split('\n').last));
      });
    }

    test('an argument is exactly one word', () async {
      final script = File('test/support/print_args.dart').absolute.path;
      const value =
          r'  two words * $HOME "q" '
          's'
          ' ';
      expect(
        await call(
          [
            CommandStep(
              "'${Platform.resolvedExecutable}' '$script' "
              'UTCP_ARG_v_UTCP_END "a-UTCP_ARG_v_UTCP_END-b"',
            ),
          ],
          arguments: {'v': value},
        ),
        [value, 'a-$value-b'],
      );
    });

    test('a glob argument is not expanded', () async {
      await File('${temp.path}/secret.txt').writeAsString('x');
      expect(
        await call(
          [const CommandStep('echo UTCP_ARG_v_UTCP_END')],
          arguments: {'v': '*'},
          workingDir: temp.path,
        ),
        '*',
      );
    });
  });

  group('environment', () {
    test('env_vars and working_dir apply to the commands', () async {
      final dir = await temp.resolveSymbolicLinks();
      expect(
        await call(
          [const CommandStep(r'echo "Var is $MY_VAR, CWD is $(pwd)"')],
          envVars: {'MY_VAR': 'Hello World'},
          workingDir: temp.path,
        ),
        'Var is Hello World, CWD is $dir',
      );
    });

    // Host variable names the script sees; bash sets PWD, SHLVL and `_`.
    Future<Set<String>> inherited({List<String>? inheritEnvVars}) async {
      final result = await call([
        const CommandStep('env'),
      ], inheritEnvVars: inheritEnvVars);
      return {
          for (final line in '$result'.split('\n')) line.split('=').first,
        }.intersection(Platform.environment.keys.toSet())
        ..removeAll(['PWD', 'SHLVL', '_', 'OLDPWD']);
    }

    test('only the default allowlist is inherited', () async {
      const allowlist = {
        'PATH', 'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'USER', 'LOGNAME', //
        'SHELL', 'TZ', 'TERM',
      };
      // The test runner always has variables outside the allowlist.
      expect(
        Platform.environment.keys.toSet().difference(allowlist),
        isNotEmpty,
      );
      final names = await inherited();
      expect(names.difference(allowlist), isEmpty);
      expect(names, contains('PATH'));
    });

    test('inherit_env_vars replaces the allowlist', () async {
      expect(await inherited(inheritEnvVars: ['HOME']), {'HOME'});
      expect(await inherited(inheritEnvVars: const []), isEmpty);
    });

    test('a missing working_dir fails the call', () async {
      await expectLater(
        call([const CommandStep('pwd')], workingDir: '${temp.path}/missing'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    });
  });

  group('discovery', () {
    Future<RegisterManualResult> register(List<CommandStep> commands) =>
        protocol.registerManual(
          client,
          CliCallTemplate(name: 'm', commands: commands, workingDir: temp.path),
        );

    final manual = {
      'utcp_version': '1.0.1',
      'tools': [
        {
          'name': 'hello',
          'description': 'Says hello',
          'tool_call_template': {
            'call_template_type': 'cli',
            'commands': [
              {'command': 'echo hello'},
            ],
          },
        },
      ],
    };

    test('the output is parsed as a manual', () async {
      await File('${temp.path}/manual.json').writeAsString(jsonEncode(manual));
      final result = await register([const CommandStep('cat manual.json')]);
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'hello');
      expect(
        result.manual.tools.single.toolCallTemplate,
        isA<CliCallTemplate>(),
      );
    });

    test('log lines around a one-line manual are tolerated', () async {
      await File('${temp.path}/manual.json').writeAsString(jsonEncode(manual));
      final result = await register([
        const CommandStep('echo starting', appendToFinalOutput: true),
        const CommandStep('cat manual.json', appendToFinalOutput: true),
        const CommandStep('echo done', appendToFinalOutput: true),
      ]);
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'hello');
    });

    test('no output is a failure', () async {
      final result = await register([const CommandStep('true')]);
      expect(result.success, isFalse);
      expect(result.errors.single, contains('No output'));
    });

    test('output that is not a manual is a failure', () async {
      final result = await register([const CommandStep('echo hello')]);
      expect(result.success, isFalse);
      expect(result.errors.single, contains('Could not parse a UTCP manual'));
    });

    test('a placeholder without an argument is a failure', () async {
      final result = await register([
        const CommandStep('echo UTCP_ARG_x_UTCP_END'),
      ]);
      expect(result.success, isFalse);
      expect(result.errors.single, contains("Missing argument 'x'"));
    });

    test('a discovery timeout is a failure', () async {
      final quick = CliCommunicationProtocol(
        discoveryTimeout: const Duration(milliseconds: 300),
      );
      final result = await quick.registerManual(
        client,
        CliCallTemplate(commands: [const CommandStep('sleep 30')]),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('timed out'));
      await quick.close();
    });
  });

  group('process cleanup', () {
    // A grandchild of the shell that records its pid, then blocks.
    List<CommandStep> blocking(File pidFile) => [
      CommandStep(
        "/bin/sh -c 'echo \$\$ > \"${pidFile.path}\"; exec sleep 30'",
      ),
    ];

    test('a timeout kills the whole process tree', () async {
      final pidFile = File('${temp.path}/pid');
      final quick = CliCommunicationProtocol(
        callTimeout: const Duration(seconds: 1),
      );
      final started = DateTime.now();
      final call = quick.callTool(
        client,
        'test.slow',
        const {},
        CliCallTemplate(commands: blocking(pidFile)),
      );
      final pid = await readPid(pidFile);
      await expectLater(
        call,
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      expect(DateTime.now().difference(started), lessThan(seconds(10)));
      expect(await diesWithin(pid), isTrue);
      await quick.close();
    });

    test('cancelling a streaming call kills the process tree', () async {
      final pidFile = File('${temp.path}/pid');
      final subscription = protocol
          .callToolStreaming(
            client,
            'test.slow',
            const {},
            CliCallTemplate(commands: blocking(pidFile)),
          )
          .listen((_) => fail('No result expected'));
      final pid = await readPid(pidFile);
      expect(await isAlive(pid), isTrue);
      await subscription.cancel();
      expect(await diesWithin(pid), isTrue);
    });

    test('close kills running calls and rejects new ones', () async {
      final pidFile = File('${temp.path}/pid');
      final call = protocol.callTool(
        client,
        'test.slow',
        const {},
        CliCallTemplate(commands: blocking(pidFile)),
      );
      final failed = expectLater(call, throwsA(isA<UtcpException>()));
      final pid = await readPid(pidFile);
      await protocol.close();
      await failed;
      expect(await diesWithin(pid), isTrue);
      await expectLater(
        protocol.callTool(
          client,
          'test.tool',
          const {},
          CliCallTemplate(commands: [const CommandStep('echo hi')]),
        ),
        throwsA(isA<UtcpException>()),
      );
    });

    test('a streaming call yields the result once', () async {
      expect(
        await protocol
            .callToolStreaming(
              client,
              'test.tool',
              const {},
              CliCallTemplate(commands: [const CommandStep('echo hi')]),
            )
            .toList(),
        ['hi'],
      );
    });
  });
}

Duration seconds(int n) => Duration(seconds: n);
