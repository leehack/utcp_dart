import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';

void main() {
  final json = <String, Object?>{
    'name': 'git_tools',
    'call_template_type': 'cli',
    'commands': [
      {
        'command': 'cd UTCP_ARG_target_dir_UTCP_END',
        'append_to_final_output': false,
      },
      {'command': 'git status --porcelain'},
    ],
    'env_vars': {'GIT_AUTHOR_NAME': 'UTCP Bot'},
    'inherit_env_vars': ['PATH', 'AWS_PROFILE'],
    'working_dir': '/tmp',
    'allowed_communication_protocols': ['cli', 'http'],
  };

  test('a template round-trips through JSON', () {
    final template = CliCallTemplate.fromJson(json);
    expect(template.commands.first.appendToFinalOutput, isFalse);
    expect(template.commands.last.appendToFinalOutput, isNull);
    expect(template.envVars, {'GIT_AUTHOR_NAME': 'UTCP Bot'});
    expect(template.inheritEnvVars, ['PATH', 'AWS_PROFILE']);
    expect(template.workingDir, '/tmp');
    expect(template.toJson(), json);
    expect(
      CliCallTemplate.fromJson(
        asJsonMap(jsonDecode(jsonEncode(template.toJson())), 'template'),
      ).toJson(),
      json,
    );
  });

  test('null and empty inherit_env_vars stay distinct', () {
    final minimal = {
      'call_template_type': 'cli',
      'commands': [
        {'command': 'ls'},
      ],
    };
    expect(CliCallTemplate.fromJson(minimal).inheritEnvVars, isNull);
    expect(CliCallTemplate.fromJson(minimal).toJson(), minimal);
    final strict = {...minimal, 'inherit_env_vars': <String>[]};
    expect(CliCallTemplate.fromJson(strict).inheritEnvVars, isEmpty);
    expect(CliCallTemplate.fromJson(strict).toJson(), strict);
  });

  test('the protocol registers the cli type', () {
    final parse = CliCommunicationProtocol().callTemplateTypes['cli']!;
    expect(parse(json), isA<CliCallTemplate>());
  });

  group('malformed templates are rejected', () {
    for (final (what, override) in [
      ('missing commands', <String, Object?>{'commands': null}),
      ('empty commands', <String, Object?>{'commands': <Object?>[]}),
      (
        'a command without text',
        <String, Object?>{
          'commands': [<String, Object?>{}],
        },
      ),
      (
        'a non-string command',
        <String, Object?>{
          'commands': [
            {'command': 1},
          ],
        },
      ),
      (
        'a non-boolean append flag',
        <String, Object?>{
          'commands': [
            {'command': 'ls', 'append_to_final_output': 'yes'},
          ],
        },
      ),
      (
        'non-string env_vars',
        <String, Object?>{
          'env_vars': {'A': 1},
        },
      ),
      (
        'non-string inherit_env_vars',
        <String, Object?>{
          'inherit_env_vars': [1],
        },
      ),
      ('a non-string working_dir', <String, Object?>{'working_dir': 1}),
      (
        'a blank command',
        <String, Object?>{
          'commands': [
            {'command': ' \n'},
          ],
        },
      ),
      (
        'auth',
        <String, Object?>{
          'auth': {'auth_type': 'basic', 'username': 'u', 'password': 'p'},
        },
      ),
    ]) {
      test(what, () {
        expect(
          () => CliCallTemplate.fromJson({...json, ...override}),
          throwsFormatException,
        );
      });
    }
  });

  test('an empty command list or a blank command is a programming error', () {
    expect(() => CliCallTemplate(commands: const []), throwsArgumentError);
    expect(
      () =>
          CliCallTemplate(commands: const [CommandStep('ls'), CommandStep('')]),
      throwsArgumentError,
    );
  });
}
