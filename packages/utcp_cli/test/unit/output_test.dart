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
    Future<String> unread() => throw TestFailure('read the capture file');

    test('the end marker and anything after it are removed', () async {
      final finished = await finishedOutput(
        output('a\nb\n__UTCP_END_n\ntrap output\n'),
        script,
        unread,
      );
      expect(finished.stdout, 'a\nb\n');
    });

    test('a missing end marker appends the stopped command output', () async {
      final finished = await finishedOutput(
        output('first\n', 'bash: oops', 3),
        script,
        () async => 'boom',
      );
      expect(finished, (
        stdout: 'first\nboom',
        stderr: 'bash: oops',
        exitCode: 3,
      ));
    });

    test('PowerShell scripts have no end marker', () async {
      final raw = output('a\n');
      expect(await finishedOutput(raw, const ShellScript('', {}), unread), raw);
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
    final hello = {
      'name': 'hello',
      'tool_call_template': {
        'call_template_type': 'cli',
        'commands': [
          {'command': 'echo hello'},
        ],
      },
    };
    final manual = {
      'utcp_version': '1.0.1',
      'manual_version': '2.0.0',
      'tools': [hello],
    };

    test('the whole output is a manual', () {
      final parsed = parseManualOutput(
        const JsonEncoder.withIndent('  ').convert(manual),
      );
      expect(parsed.manual.manualVersion, '2.0.0');
      expect(parsed.manual.tools.single.name, 'hello');
    });

    test('a one-line manual among log lines is found', () {
      final parsed = parseManualOutput(
        'loading...\n{"note": "not a manual"}\n${jsonEncode(manual)}\ndone\n',
      );
      expect(parsed.manual.tools.single.name, 'hello');
    });

    test('a bare list of tools is a manual', () {
      final parsed = parseManualOutput(jsonEncode([hello]));
      expect(parsed.manual.tools.single.name, 'hello');
      expect(parsed.skipped, isEmpty);
    });

    test('a single tool is a manual', () {
      final tool = {...hello, 'description': 'Hi'};
      final parsed = parseManualOutput(jsonEncode(tool));
      expect(parsed.manual.tools.single.description, 'Hi');
    });

    test('single tools on separate lines are collected', () {
      final tool = {...hello, 'description': 'Hi'};
      final parsed = parseManualOutput(
        'log\n${jsonEncode(tool)}\n${jsonEncode({...tool, 'name': 'bye'})}\n',
      );
      expect(parsed.manual.tools.map((t) => t.name), ['hello', 'bye']);
    });

    test('a malformed tool is skipped with its reason', () {
      final parsed = parseManualOutput(
        jsonEncode({
          'utcp_version': '1.0.1',
          'tools': [
            {'name': 'broken'},
            hello,
          ],
        }),
      );
      expect(parsed.manual.tools.single.name, 'hello');
      expect(parsed.manual.utcpVersion, '1.0.1');
      expect(parsed.skipped.single, startsWith("Skipped tool 0 'broken':"));
    });

    test('output without a manual is rejected', () {
      expect(() => parseManualOutput('hello'), throwsFormatException);
      expect(() => parseManualOutput('{"a": 1}'), throwsFormatException);
    });

    test('a manual whose tools are all malformed is rejected', () {
      for (final text in [
        '[1, 2]',
        jsonEncode({
          'utcp_version': '1.0.1',
          'tools': [
            {'name': 'x'},
          ],
        }),
      ]) {
        expect(
          () => parseManualOutput(text),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              startsWith('No valid tools. Skipped tool 0'),
            ),
          ),
        );
      }
    });
  });
}
