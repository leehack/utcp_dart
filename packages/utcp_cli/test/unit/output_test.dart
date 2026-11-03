import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/src/output.dart';
import 'package:utcp_cli/src/shell_script.dart';
import 'package:utcp_cli/utcp_cli.dart';

void main() {
  setUpAll(
    () => CallTemplate.registry.register(
      CliCallTemplate.type,
      CliCallTemplate.fromJson,
    ),
  );

  ScriptOutput output(String stdout, [String stderr = '', int exitCode = 0]) =>
      (stdout: stdout, stderr: stderr, exitCode: exitCode);

  group('script end', () {
    const script = ShellScript('', {}, endMarker: '__UTCP_END_n');

    test('the end marker is removed', () {
      expect(
        requireFinished(output('a\nb\n__UTCP_END_n\n'), script).stdout,
        'a\nb\n',
      );
    });

    test('a missing end marker fails with the shell error', () {
      expect(
        () => requireFinished(output('a\n', 'bash: oops', 3), script),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('exit code 3'), contains('bash: oops')),
          ),
        ),
      );
    });

    test('PowerShell scripts have no end marker', () {
      final raw = output('a\n');
      expect(requireFinished(raw, const ShellScript('', {})), raw);
    });
  });

  group('tool output', () {
    test('text is trimmed', () {
      expect(parseToolOutput(output('  hello\n\n'), Shell.bash), 'hello');
    });

    test('JSON objects and arrays are decoded', () {
      expect(parseToolOutput(output('{"a": 1}\n'), Shell.bash), {'a': 1});
      expect(parseToolOutput(output('[1, 2]'), Shell.bash), [1, 2]);
    });

    test('text that only looks like JSON stays text', () {
      expect(parseToolOutput(output('{oops'), Shell.bash), '{oops');
      expect(parseToolOutput(output('42'), Shell.bash), '42');
    });

    test('bash falls back to stderr only when stdout is blank', () {
      expect(parseToolOutput(output(' \n', 'boom', 2), Shell.bash), 'boom');
      expect(parseToolOutput(output('out', 'err', 2), Shell.bash), 'out');
    });

    test('PowerShell uses stderr when the exit code is non-zero', () {
      expect(parseToolOutput(output('out', 'err', 1), Shell.powershell), 'err');
      expect(parseToolOutput(output('out', 'err'), Shell.powershell), 'out');
    });

    test('no output is an empty string', () {
      expect(parseToolOutput(output(''), Shell.bash), '');
    });
  });

  group('discovery output', () {
    final manual = {
      'utcp_version': '1.0.1',
      'manual_version': '2.0.0',
      'tools': [
        {
          'name': 'hello',
          'tool_call_template': {
            'call_template_type': 'cli',
            'commands': [
              {'command': 'echo hello'},
            ],
          },
        },
      ],
    };

    test('the whole output is a manual', () {
      final parsed = parseManualOutput(
        const JsonEncoder.withIndent('  ').convert(manual),
      );
      expect(parsed.manualVersion, '2.0.0');
      expect(parsed.tools.single.name, 'hello');
    });

    test('a one-line manual among log lines is found', () {
      final parsed = parseManualOutput(
        'loading...\n{"note": "not a manual"}\n${jsonEncode(manual)}\ndone\n',
      );
      expect(parsed.tools.single.name, 'hello');
    });

    test('output without a manual is rejected', () {
      expect(() => parseManualOutput('hello'), throwsFormatException);
      expect(() => parseManualOutput('[1, 2]'), throwsFormatException);
      expect(() => parseManualOutput('{"a": 1}'), throwsFormatException);
    });

    test('a manual with a malformed tool is rejected', () {
      expect(
        () => parseManualOutput(
          jsonEncode({
            'utcp_version': '1.0.1',
            'tools': [
              {'name': 'x'},
            ],
          }),
        ),
        throwsFormatException,
      );
    });
  });
}
