@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

void main() {
  group('parseDotEnv', () {
    // Cases from python-dotenv's parser and dotenv_values tests, which the
    // UTCP Python SDK's loader is built on.
    for (final (source, expected) in <(String, Map<String, String?>)>[
      ('', {}),
      ('a=b', {'a': 'b'}),
      ("'a'=b", {'a': 'b'}),
      ('[=b', {'[': 'b'}),
      (' a = b ', {'a': 'b'}),
      ('export a=b', {'a': 'b'}),
      (" export 'a'=b", {'a': 'b'}),
      ('export export_a=1', {'export_a': '1'}),
      ('export port=8000', {'port': '8000'}),
      ('# a=b', {}),
      ('a=b#c', {'a': 'b#c'}),
      ('a=b #c', {'a': 'b'}),
      ('a=b\t#c', {'a': 'b'}),
      ('a= #b', {'a': ''}),
      ('a=  # b', {'a': ''}),
      ('a=#b', {'a': '#b'}),
      ('a=# # comment', {'a': '#'}),
      ('a=\t#c', {'a': ''}),
      ('a= #c\nd=e', {'a': '', 'd': 'e'}),
      ('a=b c', {'a': 'b c'}),
      ('a=b\tc', {'a': 'b\tc'}),
      ('a=b  c', {'a': 'b  c'}),
      ('a=b  c', {'a': 'b  c'}),
      ('a=b c ', {'a': 'b c'}),
      ("a='b c '", {'a': 'b c '}),
      ('a="b c "', {'a': 'b c '}),
      ('a="b\nc"', {'a': 'b\nc'}),
      ("a='b\nc'", {'a': 'b\nc'}),
      (r'a="b\nc"', {'a': 'b\nc'}),
      (r"a='b\nc'", {'a': r'b\nc'}),
      (r'a="b\"c"', {'a': 'b"c'}),
      (r"a='b\'c'", {'a': "b'c"}),
      (r"a='b\\c'", {'a': r'b\c'}),
      (r'a="b\\c"', {'a': r'b\c'}),
      ("a='b\\\\'\nc='d'", {'a': r'b\', 'c': 'd'}),
      ('a="b\\\\"\nc="d"', {'a': r'b\', 'c': 'd'}),
      (r"a='b\\\'c'", {'a': r"b\'c"}),
      (r'a="\t\a\b\f\r\v"', {'a': '\t\x07\b\f\r\v'}),
      ('a=à', {'a': 'à'}),
      ('a="à"', {'a': 'à'}),
      ('no_value_var', {'no_value_var': null}),
      ('a: b', {}),
      ('a=b\nc=d', {'a': 'b', 'c': 'd'}),
      ('a=b\rc=d', {'a': 'b', 'c': 'd'}),
      ('a=b\r\nc=d', {'a': 'b', 'c': 'd'}),
      ('a=\nb=c', {'a': '', 'b': 'c'}),
      ('\n\n', {}),
      ('a=b\n\n', {'a': 'b'}),
      ('a=b\n\nc=d', {'a': 'b', 'c': 'd'}),
      ('a="\nb=c', {'b': 'c'}),
      ('# comment\na="b\nc"\nd=e\n', {'a': 'b\nc', 'd': 'e'}),
      ('a=b\n# comment 1', {'a': 'b'}),
      ('# comment 1\n# comment 2', {}),
      (
        'uglyKey[%\$="S3cr3t_P4ssw#rD" #\na=b',
        {'uglyKey[%\$': 'S3cr3t_P4ssw#rD', 'a': 'b'},
      ),
      ('﻿a=b', {'a': 'b'}),
      ('﻿a=b\nc=d', {'a': 'b', 'c': 'd'}),
      ('a=b\na=c', {'a': 'c'}),
    ]) {
      test(source.replaceAll('\n', r'\n'), () {
        expect(parseDotEnv(source), expected);
      });
    }

    group('expands \${NAME}', () {
      for (final (env, source, expected)
          in <(Map<String, String>, String, Map<String, String?>)>[
            ({'b': 'c'}, r'a=${b}', {'a': 'c'}),
            ({'b': 'c'}, r'a=${b:-d}', {'a': 'c'}),
            ({}, 'b=c\na=\${b}', {'a': 'c', 'b': 'c'}),
            ({}, r'a=${b}', {'a': ''}),
            ({}, r'a=${b:-d}', {'a': 'd'}),
            ({'b': 'c'}, r'a="${b}"', {'a': 'c'}),
            ({'b': 'c'}, r"a='${b}'", {'a': 'c'}),
            ({'b': 'c'}, r'a=x${b}y', {'a': 'xcy'}),
            ({'a': 'b'}, r'a=${a}', {'a': 'b'}),
            ({}, r'a=${a}', {'a': ''}),
            ({'a': 'b'}, r'a=${a:-c}', {'a': 'b'}),
            ({}, r'a=${a:-c}', {'a': 'c'}),
            ({'b': 'c'}, r'a=${b}${b}', {'a': 'cc'}),
            ({'b': 'c'}, 'b=d\na=\${b}', {'a': 'd', 'b': 'd'}),
            ({}, 'a=b\na=c\nd=\${a}', {'a': 'c', 'd': 'c'}),
            ({}, 'a=b\nc=\${a}\nd=e\nc=\${d}', {'a': 'b', 'c': 'e', 'd': 'e'}),
            ({}, 'b\na=\${b:-x}', {'b': null, 'a': ''}),
            ({'b': 'c'}, r'a=$b', {'a': r'$b'}),
          ]) {
        test('$source with $env', () {
          expect(parseDotEnv(source, environment: env), expected);
        });
      }
    });
  });

  group('DotEnvVariableLoader', () {
    late Directory temp;

    setUp(
      () async => temp = await Directory.systemTemp.createTemp('utcp_dotenv_'),
    );
    tearDown(() => temp.delete(recursive: true));

    test('reads the file on every lookup', () async {
      final file = File('${temp.path}/.env');
      await file.writeAsString('export API_KEY="one" # first\n');
      final loader = DotEnvVariableLoader(file.path, environment: const {});
      expect(await loader.get('API_KEY'), 'one');
      expect(await loader.get('OTHER'), isNull);
      await file.writeAsString('API_KEY=two\n');
      expect(await loader.get('API_KEY'), 'two');
    });

    test('a missing file defines nothing', () async {
      final loader = DotEnvVariableLoader('${temp.path}/missing.env');
      expect(await loader.get('API_KEY'), isNull);
    });

    test('values expand from the environment', () async {
      final file = File('${temp.path}/.env');
      await file.writeAsString(r'URL=https://${HOST}/v1');
      final loader = DotEnvVariableLoader(
        file.path,
        environment: const {'HOST': 'api.example.com'},
      );
      expect(await loader.get('URL'), 'https://api.example.com/v1');
    });

    test('parses from JSON once registered', () {
      final json = {'variable_loader_type': 'dotenv', 'env_file_path': '.env'};
      DotEnvVariableLoader.register();
      DotEnvVariableLoader.register();
      final loader = VariableLoader.registry.parse(json);
      expect(loader, isA<DotEnvVariableLoader>());
      expect((loader as DotEnvVariableLoader).toJson(), json);
    });

    test('a config without env_file_path is rejected', () {
      expect(
        () => DotEnvVariableLoader.fromJson({'variable_loader_type': 'dotenv'}),
        throwsFormatException,
      );
    });
  });
}
