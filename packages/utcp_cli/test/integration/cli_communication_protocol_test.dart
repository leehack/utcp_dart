@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
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
        await call([const CommandStep('echo "unterminated')]),
        contains('unexpected EOF'),
      );
    });

    for (final (command, expected) in [
      ('echo hello; exit 3', 'hello'),
      ('exit 0', ''),
      ('set -e; echo hello; false', 'hello'),
      ('exec echo hello', 'hello'),
    ]) {
      test(
        'a command that ends the script returns its output: $command',
        () async {
          expect(
            await call([
              CommandStep(command, appendToFinalOutput: true),
              const CommandStep('echo world'),
            ]),
            expected,
          );
        },
      );
    }

    test('outputs selected before the ending command are kept', () async {
      expect(
        await call([
          const CommandStep('echo first', appendToFinalOutput: true),
          const CommandStep('echo skipped', appendToFinalOutput: false),
          const CommandStep(
            'echo boom >&2; exit 3',
            appendToFinalOutput: false,
          ),
          const CommandStep('echo never'),
        ]),
        'first\nboom',
      );
    });

    test('output over maxOutputBytes fails the call', () async {
      final small = CliCommunicationProtocol(maxOutputBytes: 1000);
      addTearDown(small.close);
      Future<Object?> printBytes(int bytes) => small.callTool(
        client,
        'test.tool',
        const {},
        CliCallTemplate(
          commands: [CommandStep("head -c $bytes /dev/zero | tr '\\0' a")],
        ),
      );
      expect(await printBytes(900), 'a' * 900);
      await expectLater(
        printBytes(5000),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('more than 1000 bytes'),
          ),
        ),
      );
    });

    test('a NUL character in an argument fails the call', () async {
      await expectLater(
        call(
          [const CommandStep('printf %s UTCP_ARG_v_UTCP_END')],
          arguments: {'v': 'a\u0000b'},
        ),
        throwsA(isA<UtcpException>()),
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

    test(r'an argument inside "$(...)" or backticks is one word', () async {
      final script = File('test/support/print_args.dart').absolute.path;
      const value = 'a  b *';
      final program = "'${Platform.resolvedExecutable}' '$script'";
      for (final command in [
        'echo "\$($program UTCP_ARG_v_UTCP_END)"',
        'echo "`$program UTCP_ARG_v_UTCP_END`"',
      ]) {
        expect(
          await call(
            [CommandStep(command)],
            arguments: {'v': value},
            workingDir: temp.path,
          ),
          [value],
          reason: command,
        );
      }
    });

    test(r'a glob argument inside "$(...)" reads no other file', () async {
      await File('${temp.path}/secret.txt').writeAsString('SECRET');
      final result = await call(
        [const CommandStep(r'echo "content: $(cat UTCP_ARG_f_UTCP_END)"')],
        arguments: {'f': '*'},
        workingDir: temp.path,
      );
      expect('$result', isNot(contains('SECRET')));
      expect('$result', contains('*'));
    });

    test('an argument in an arithmetic context is rejected, not run', () async {
      const payload = r'a[$(touch "$CANARY")]';
      // The exploit value carries an array subscript with a command
      // substitution, so it is refused in any context: the arithmetic ones
      // by the scanner and `[ ]` by the value check.
      for (final command in [
        'if [[ UTCP_ARG_n_UTCP_END -gt 3 ]]; then echo big; fi',
        r'echo $(( UTCP_ARG_n_UTCP_END + 1 ))',
        '[ UTCP_ARG_n_UTCP_END -gt 3 ] && echo big',
      ]) {
        await expectLater(
          call(
            [CommandStep(command)],
            arguments: {'n': payload},
            envVars: {'CANARY': canary().path},
          ),
          throwsA(isA<UtcpException>()),
          reason: command,
        );
      }
      expect(canary().existsSync(), isFalse);
      // `[ ]` accepts only integer literals, so a non-integer value is a safe
      // error rather than evaluated arithmetic.
      expect(
        '${await call([const CommandStep('[ UTCP_ARG_n_UTCP_END -gt 3 ] && echo big')], arguments: {'n': 'notanumber'})}',
        matches(RegExp('integer (expression )?expected')),
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

  group('scanner bypasses', () {
    File canary() => File('${temp.path}/pwned');

    test(
      'a heredoc body does not desync quoting for a later placeholder',
      () async {
        await File('${temp.path}/secret.txt').writeAsString('SECRET');
        expect(
          await call(
            [
              const CommandStep(
                'cat <<EOF\nsay "hi\nEOF\nprintf \'<%s>\' '
                'UTCP_ARG_v_UTCP_END',
              ),
            ],
            arguments: {'v': 'a  b *'},
            workingDir: temp.path,
          ),
          'say "hi\n<a  b *>',
        );
      },
    );

    test(
      'a case in a command substitution is rejected before running',
      () async {
        final canaryFile = canary();
        await expectLater(
          call(
            [
              const CommandStep(
                'printf %s "\$(case x in x) printf %s '
                'UTCP_ARG_v_UTCP_END;; esac)"',
              ),
            ],
            arguments: {'v': r'$(touch "$CANARY")'},
            envVars: {'CANARY': canaryFile.path},
          ),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('case'),
            ),
          ),
        );
        expect(canaryFile.existsSync(), isFalse);
      },
    );

    test(
      'an integer declaration in a group or function body is rejected',
      () async {
        final canaryFile = canary();
        for (final command in [
          '{ declare -i n=UTCP_ARG_v_UTCP_END; }',
          'f() { local -i n=UTCP_ARG_v_UTCP_END; }; f',
          'builtin declare -i n=UTCP_ARG_v_UTCP_END',
          'command let n=UTCP_ARG_v_UTCP_END',
        ]) {
          await expectLater(
            call(
              [CommandStep(command)],
              arguments: {'v': r'a[$(touch "$CANARY")]'},
              envVars: {'CANARY': canaryFile.path},
            ),
            throwsA(isA<UtcpException>()),
            reason: command,
          );
        }
        expect(canaryFile.existsSync(), isFalse);
      },
    );

    test('a shift in arithmetic does not start a heredoc', () async {
      await File('${temp.path}/secret.txt').writeAsString('SECRET');
      for (final shift in [r'x=$((1<<2))', '(( y = 1 << 3 ))']) {
        expect(
          await call(
            [CommandStep("$shift\nprintf '<%s>' UTCP_ARG_v_UTCP_END")],
            arguments: {'v': 'a  b *'},
            workingDir: temp.path,
          ),
          '<a  b *>',
          reason: shift,
        );
      }
    });

    test('a heredoc in a command substitution', () async {
      expect(
        await call(
          [
            const CommandStep(
              'x=\$(cat <<EOF\nUTCP_ARG_v_UTCP_END\nEOF\n)\n'
              "printf '<%s>' \"\$x\" UTCP_ARG_v_UTCP_END",
            ),
          ],
          arguments: {'v': 'a  b *'},
          workingDir: temp.path,
        ),
        '<a  b *><a  b *>',
      );
      await expectLater(
        call(
          [
            const CommandStep(
              "x=\$(cat <<EOF\nhi\nEOF)\nprintf '<%s>' UTCP_ARG_v_UTCP_END",
            ),
          ],
          arguments: {'v': 'a  b *'},
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('heredoc'),
          ),
        ),
      );
    });

    test('values split across placeholders are rejected', () async {
      final canaryFile = canary();
      for (final command in [
        'arr=([AB]=x)',
        '[[ -v AB ]]',
        "'let' x=AB",
        'command -p let x=AB',
        'time -p let x=AB',
        'declare -i n; n=AB',
      ]) {
        await expectLater(
          call(
            [
              CommandStep(
                command.replaceFirst(
                  'AB',
                  'UTCP_ARG_a_UTCP_ENDUTCP_ARG_b_UTCP_END',
                ),
              ),
            ],
            arguments: {'a': 'y[', 'b': r'$(touch "$CANARY")]'},
            envVars: {'CANARY': canaryFile.path},
          ),
          throwsA(isA<UtcpException>()),
          reason: command,
        );
      }
      expect(canaryFile.existsSync(), isFalse);
    });

    test('text with brackets and backticks passes', () async {
      const value = 'See [docs](https://x) and run `make`';
      expect(
        await call(
          [const CommandStep("printf '<%s>' UTCP_ARG_v_UTCP_END")],
          arguments: {'v': value},
        ),
        '<$value>',
      );
    });

    test('an escaped blank before `#` does not start a comment', () async {
      expect(
        await call(
          [const CommandStep(r'''printf '<%s>' x\ #" UTCP_ARG_v_UTCP_END "''')],
          arguments: {'v': 'a  b'},
        ),
        '<x # a  b >',
      );
    });

    test('a value with `[` and a command substitution is rejected', () async {
      final canaryFile = canary();
      await expectLater(
        call(
          [const CommandStep('echo UTCP_ARG_v_UTCP_END')],
          arguments: {'v': r'x[$(touch "$CANARY")]'},
          envVars: {'CANARY': canaryFile.path},
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(contains("'v'"), contains('subscript')),
          ),
        ),
      );
      expect(canaryFile.existsSync(), isFalse);
    });

    test('a JSON array value still passes', () async {
      expect(
        await call(
          [const CommandStep('printf %s UTCP_ARG_v_UTCP_END')],
          arguments: {
            'v': [1, 2, 3],
          },
        ),
        [1, 2, 3],
      );
    });

    test('a trap on EXIT does not fail the call', () async {
      expect(
        await call([const CommandStep("trap 'echo trap-ran' EXIT; echo hi")]),
        'hi',
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

    final hello = {
      'name': 'hello',
      'description': 'Says hello',
      'tool_call_template': {
        'call_template_type': 'cli',
        'commands': [
          {'command': 'echo hello'},
        ],
      },
    };
    final manual = {
      'utcp_version': '1.0.1',
      'tools': [hello],
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

    test('a bare list of tools is a manual', () async {
      await File('${temp.path}/tools.json').writeAsString(jsonEncode([hello]));
      final result = await register([const CommandStep('cat tools.json')]);
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'hello');
    });

    test('a bad tool is skipped, not the whole manual', () async {
      await File('${temp.path}/manual.json').writeAsString(
        jsonEncode({
          ...manual,
          'tools': [
            {'name': 'broken'},
            hello,
          ],
        }),
      );
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      final result = await register([const CommandStep('cat manual.json')]);
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'hello');
      expect(
        records.map((r) => r.message),
        contains(allOf(contains("CLI manual 'm'"), contains("'broken'"))),
      );
    });

    test('a manual whose discovery command exits still registers', () async {
      await File('${temp.path}/manual.json').writeAsString(jsonEncode(manual));
      final result = await register([
        const CommandStep('cat manual.json; exit 1'),
      ]);
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'hello');
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
      // A timeout far beyond the test's own, so only the cancel can stop it.
      final patient = CliCommunicationProtocol(
        callTimeout: const Duration(minutes: 10),
      );
      addTearDown(patient.close);
      final subscription = patient
          .callToolStreaming(
            client,
            'test.slow',
            const {},
            CliCallTemplate(commands: blocking(pidFile)),
          )
          .listen((_) => fail('No result expected'));
      final pid = await readPid(pidFile);
      expect(await isAlive(pid), isTrue);
      await subscription.cancel().timeout(seconds(5));
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
