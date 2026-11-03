import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/src/shell_script.dart';
import 'package:utcp_cli/utcp_cli.dart';

void main() {
  const nonce = 'abc123';
  const v = '__UTCP_ARG_abc123_v';

  (String, Map<String, String>) substitute(
    String command,
    ToolArguments arguments, {
    Shell shell = Shell.bash,
  }) {
    final environment = <String, String>{};
    final result = substitutePlaceholders(
      command,
      arguments,
      shell: shell,
      nonce: nonce,
      environment: environment,
    );
    return (result, environment);
  }

  group('bash placeholders', () {
    test('bare placeholders become a quoted variable', () {
      final (command, environment) = substitute('cat UTCP_ARG_v_UTCP_END', {
        'v': 'x',
      });
      expect(command, 'cat "\$$v"');
      expect(environment, {v: 'x'});
    });

    test('placeholders inside double quotes become a braced variable', () {
      expect(
        substitute('curl "https://api/UTCP_ARG_v_UTCP_END/x"', {'v': 'x'}).$1,
        'curl "https://api/\${$v}/x"',
      );
    });

    test('placeholders inside single quotes break out of the quotes', () {
      expect(
        substitute("echo 'a UTCP_ARG_v_UTCP_END b'", {'v': 'x'}).$1,
        "echo 'a '\"\$$v\"' b'",
      );
    });

    test('an escaped double quote does not end the quoted region', () {
      expect(
        substitute(r'echo "a \" UTCP_ARG_v_UTCP_END"', {'v': 'x'}).$1,
        'echo "a \\" \${$v}"',
      );
      expect(
        substitute(r'echo \" UTCP_ARG_v_UTCP_END', {'v': 'x'}).$1,
        'echo \\" "\$$v"',
      );
    });

    test('a backslash inside single quotes is literal', () {
      expect(
        substitute(r"echo 'a\' UTCP_ARG_v_UTCP_END", {'v': 'x'}).$1,
        'echo \'a\\\' "\$$v"',
      );
    });

    test('several placeholders compose into one word', () {
      final (command, environment) = substitute(
        '"UTCP_ARG_id_UTCP_END/UTCP_ARG_action_UTCP_END"',
        {'id': '1', 'action': 'go'},
      );
      expect(command, r'"${__UTCP_ARG_abc123_id}/${__UTCP_ARG_abc123_action}"');
      expect(environment, {
        '__UTCP_ARG_abc123_id': '1',
        '__UTCP_ARG_abc123_action': 'go',
      });
    });

    test('names with underscores match up to the first _UTCP_END', () {
      expect(
        substitute('UTCP_ARG_target_dir_UTCP_END', {'target_dir': 'x'}).$2,
        {'__UTCP_ARG_abc123_target_dir': 'x'},
      );
    });

    test('attacker bytes never reach the command text', () {
      for (final payload in [
        '"; rm -rf /; "',
        "'; rm -rf /; '",
        r'$(rm -rf /)',
        '`rm -rf /`',
        'a\nrm -rf /',
      ]) {
        for (final template in [
          'echo UTCP_ARG_v_UTCP_END',
          'echo "UTCP_ARG_v_UTCP_END"',
          "echo 'UTCP_ARG_v_UTCP_END'",
        ]) {
          final (command, environment) = substitute(template, {'v': payload});
          expect(command, isNot(contains('rm')));
          expect(environment[v], payload);
        }
      }
    });

    test('non-string values are JSON-encoded', () {
      expect(
        substitute(
          'UTCP_ARG_a_UTCP_END UTCP_ARG_b_UTCP_END UTCP_ARG_c_UTCP_END '
          'UTCP_ARG_d_UTCP_END',
          {
            'a': 1.5,
            'b': true,
            'c': null,
            'd': [1, 'x'],
          },
        ).$2.values,
        ['1.5', 'true', 'null', '[1,"x"]'],
      );
    });

    test(r'code inside $(...) and backticks resets the quoting', () {
      expect(
        substitute(r'echo "n: $(cat UTCP_ARG_v_UTCP_END)"', {'v': 'x'}).$1,
        'echo "n: \$(cat "\$$v")"',
      );
      expect(
        substitute('echo "n: `cat UTCP_ARG_v_UTCP_END`"', {'v': 'x'}).$1,
        'echo "n: `cat "\$$v"`"',
      );
      expect(
        substitute(
          r'''echo "$(printf '%s' 'UTCP_ARG_v_UTCP_END')"''',
          {'v': 'x'},
        ).$1,
        'echo "\$(printf \'%s\' \'\'"\$$v"\'\')"',
      );
      expect(
        substitute(
          r'echo "$(echo "UTCP_ARG_v_UTCP_END")" UTCP_ARG_v_UTCP_END',
          {'v': 'x'},
        ).$1,
        'echo "\$(echo "\${$v}")" "\$$v"',
      );
    });

    test('a quote inside a comment does not change the quoting', () {
      expect(
        substitute("echo hi # don't\nprintf '%s' UTCP_ARG_v_UTCP_END", {
          'v': 'x',
        }).$1,
        "echo hi # don't\nprintf '%s' \"\$$v\"",
      );
      expect(
        substitute('echo a#b UTCP_ARG_v_UTCP_END', {'v': 'x'}).$1,
        'echo a#b "\$$v"',
      );
    });

    test(r"placeholders inside $'...' resume ANSI-C quoting", () {
      expect(
        substitute(r"echo $'a\' UTCP_ARG_v_UTCP_END'", {'v': 'x'}).$1,
        'echo \$\'a\\\' \'"\$$v"\$\'\'',
      );
    });

    group('arithmetic contexts are rejected:', () {
      for (final command in [
        r'echo $((UTCP_ARG_v_UTCP_END + 1))',
        r'echo "$(( UTCP_ARG_v_UTCP_END ))"',
        '(( UTCP_ARG_v_UTCP_END > 3 ))',
        'for ((i = 0; i < UTCP_ARG_v_UTCP_END; i++)); do :; done',
        r'echo $[UTCP_ARG_v_UTCP_END]',
        r'echo ${x:UTCP_ARG_v_UTCP_END}',
        r'echo "${a[UTCP_ARG_v_UTCP_END]}"',
        'a[UTCP_ARG_v_UTCP_END]=1',
        '[[ UTCP_ARG_v_UTCP_END -gt 3 ]]',
        'if [[ "UTCP_ARG_v_UTCP_END" -eq 3 ]]; then echo y; fi',
        '[[ x == y || UTCP_ARG_v_UTCP_END -le 3 ]]',
        'let n=UTCP_ARG_v_UTCP_END',
        'if true; then let "n = UTCP_ARG_v_UTCP_END"; fi',
        'declare -i n=UTCP_ARG_v_UTCP_END',
        'local -ri n=UTCP_ARG_v_UTCP_END',
        r'echo $(( $(echo UTCP_ARG_v_UTCP_END) ))',
        r'let n=$(echo UTCP_ARG_v_UTCP_END)',
        "(( 'UTCP_ARG_v_UTCP_END' ))",
      ]) {
        test(command, () {
          expect(
            () => substitute(command, {'v': '1'}),
            throwsA(
              isA<UtcpException>().having(
                (e) => e.message,
                'message',
                allOf(contains('UTCP_ARG_v_UTCP_END'), contains('run code')),
              ),
            ),
          );
        });
      }
    });

    test('other contexts are allowed', () {
      for (final command in [
        '[ UTCP_ARG_v_UTCP_END -gt 3 ]',
        'test UTCP_ARG_v_UTCP_END -eq 3',
        '[[ UTCP_ARG_v_UTCP_END == 3 ]]',
        r'[[ -n "UTCP_ARG_v_UTCP_END" ]] && echo $((1 + 2))',
        r'echo $((1 + 2)) UTCP_ARG_v_UTCP_END',
        'export N=UTCP_ARG_v_UTCP_END',
        'local n=UTCP_ARG_v_UTCP_END',
        'let n=1; echo UTCP_ARG_v_UTCP_END',
        'echo let UTCP_ARG_v_UTCP_END',
        'echo "a[UTCP_ARG_v_UTCP_END]"',
        r'echo "${HOME}/UTCP_ARG_v_UTCP_END"',
      ]) {
        expect(substitute(command, {'v': '1'}).$2, {v: '1'}, reason: command);
      }
    });

    test('a NUL character in an argument is rejected', () {
      expect(
        () => substitute('printf %s UTCP_ARG_v_UTCP_END', {'v': 'a\u0000b'}),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(contains("'v'"), contains('NUL')),
          ),
        ),
      );
    });

    test('a missing argument is an error', () {
      expect(
        () => substitute('echo UTCP_ARG_v_UTCP_END', {}),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains("'v'"),
          ),
        ),
      );
    });
  });

  group('PowerShell placeholders', () {
    String ps(String command) =>
        substitute(command, {'v': 'x'}, shell: Shell.powershell).$1;

    test('bare and double-quoted placeholders become a braced env var', () {
      expect(ps('Get-Item UTCP_ARG_v_UTCP_END'), 'Get-Item \${env:$v}');
      expect(ps('echo "id=UTCP_ARG_v_UTCP_END"'), 'echo "id=\${env:$v}"');
    });

    test('a suffix cannot extend the variable name', () {
      expect(ps('"UTCP_ARG_v_UTCP_END123"'), '"\${env:$v}123"');
    });

    test('a placeholder inside single quotes is rejected', () {
      expect(
        () => ps("echo 'UTCP_ARG_v_UTCP_END'"),
        throwsA(isA<UtcpException>()),
      );
    });

    test("'' and backtick escapes do not flip the quote state", () {
      expect(ps("echo 'it''s' UTCP_ARG_v_UTCP_END"), "echo 'it''s' \${env:$v}");
      expect(ps('echo "a`" UTCP_ARG_v_UTCP_END"'), 'echo "a`" \${env:$v}"');
    });
  });

  group('scripts', () {
    final commands = [
      const CommandStep('cd UTCP_ARG_v_UTCP_END'),
      const CommandStep('ls', appendToFinalOutput: true),
      const CommandStep('pwd', appendToFinalOutput: false),
      const CommandStep('whoami'),
    ];

    test(
      'bash runs commands in the script shell and prints selected outputs',
      () {
        final script = buildShellScript(
          commands,
          {'v': 'dir'},
          shell: Shell.bash,
          nonce: nonce,
          captureFile: '/tmp/out',
        );
        expect(script.environment, {'__UTCP_OUT_abc123': '/tmp/out', v: 'dir'});
        final lines = script.source.split('\n');
        expect(lines.take(5), [
          '{ cd "\$$v"',
          r'} >"$__UTCP_OUT_abc123" 2>&1',
          r'__utcp_status=$?',
          r'CMD_0_OUTPUT=$(<"$__UTCP_OUT_abc123")',
          r'(exit $__utcp_status)',
        ]);
        expect(lines.where((l) => l.startsWith('printf')), [
          r'''printf '%s\n' "${CMD_1_OUTPUT}"''',
          r'''printf '%s\n' "${CMD_3_OUTPUT}"''',
          r"printf '%s\n' __UTCP_END_abc123",
        ]);
        expect(script.endMarker, '__UTCP_END_abc123');
      },
    );

    test('only the last output is printed when no command opts in', () {
      final script = buildShellScript(
        [const CommandStep('a'), const CommandStep('b')],
        {},
        shell: Shell.bash,
        nonce: nonce,
        captureFile: '/tmp/out',
      );
      expect(script.source.split('\n').where((l) => l.startsWith('printf')), [
        r'''printf '%s\n' "${CMD_1_OUTPUT}"''',
        r"printf '%s\n' __UTCP_END_abc123",
      ]);
    });

    test('PowerShell captures each command into a variable', () {
      final script = buildShellScript(
        commands,
        {'v': 'dir'},
        shell: Shell.powershell,
        nonce: nonce,
      );
      expect(script.source.split('\n'), [
        r'$ErrorActionPreference = "Stop"',
        '\$CMD_0_OUTPUT = cd \${env:$v} 2>&1 | Out-String',
        r'$CMD_1_OUTPUT = ls 2>&1 | Out-String',
        r'$CMD_2_OUTPUT = pwd 2>&1 | Out-String',
        r'$CMD_3_OUTPUT = whoami 2>&1 | Out-String',
        r'Write-Output $CMD_1_OUTPUT',
        r'Write-Output $CMD_3_OUTPUT',
      ]);
      expect(script.endMarker, isNull);
    });

    test('bash needs a capture file', () {
      expect(
        () => buildShellScript(
          commands,
          {'v': 'x'},
          shell: Shell.bash,
          nonce: nonce,
        ),
        throwsArgumentError,
      );
    });

    test('nonces are fresh 16-digit hex strings', () {
      final nonces = {for (var i = 0; i < 20; i++) randomNonce()};
      expect(nonces, hasLength(20));
      expect(nonces, everyElement(matches(RegExp(r'^[0-9a-f]{16}$'))));
    });
  });

  group('subprocess environment', () {
    const host = {
      'PATH': '/bin',
      'HOME': '/home/me',
      'OPENAI_API_KEY': 'secret',
      'SYSTEMROOT': r'C:\Windows',
    };
    const script = ShellScript('', {'__UTCP_ARG_n_v': 'arg'});

    Map<String, String> environment(
      Shell shell, {
      Map<String, String>? envVars,
      List<String>? inheritEnvVars,
    }) => subprocessEnvironment(
      CliCallTemplate(
        commands: [const CommandStep('ls')],
        envVars: envVars,
        inheritEnvVars: inheritEnvVars,
      ),
      script,
      host,
      shell,
    );

    test('the default allowlist keeps secrets out', () {
      expect(environment(Shell.bash), {
        'PATH': '/bin',
        'HOME': '/home/me',
        '__UTCP_ARG_n_v': 'arg',
      });
      expect(environment(Shell.powershell), {
        'PATH': '/bin',
        'SYSTEMROOT': r'C:\Windows',
        '__UTCP_ARG_n_v': 'arg',
      });
    });

    test('inherit_env_vars replaces the allowlist and skips unset names', () {
      expect(
        environment(Shell.bash, inheritEnvVars: ['OPENAI_API_KEY', 'NOPE']),
        {'OPENAI_API_KEY': 'secret', '__UTCP_ARG_n_v': 'arg'},
      );
      expect(environment(Shell.bash, inheritEnvVars: const []), {
        '__UTCP_ARG_n_v': 'arg',
      });
    });

    test('env_vars override inherited values', () {
      expect(environment(Shell.bash, envVars: {'PATH': '/opt/bin', 'X': '1'}), {
        'PATH': '/opt/bin',
        'HOME': '/home/me',
        'X': '1',
        '__UTCP_ARG_n_v': 'arg',
      });
    });
  });
}
