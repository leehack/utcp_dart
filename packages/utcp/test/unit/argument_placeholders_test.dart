import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

void main() {
  group('substituteArgumentPlaceholders', () {
    test('strings as they are, other values as JSON', () {
      expect(
        substituteArgumentPlaceholders(
          'UTCP_ARG_cmd_UTCP_ARG UTCP_ARG_n_UTCP_ARG UTCP_ARG_on_UTCP_ARG '
          'UTCP_ARG_tags_UTCP_ARG UTCP_ARG_none_UTCP_ARG UTCP_ARG_cmd_UTCP_ARG',
          {
            'cmd': 'SET "x"',
            'n': 25,
            'on': true,
            'tags': ['a'],
            'none': null,
          },
        ),
        'SET "x" 25 true ["a"] null SET "x"',
      );
    });

    test('keeps placeholders without an argument', () {
      expect(
        substituteArgumentPlaceholders(
          'ID=UTCP_ARG_user_id_UTCP_ARG X=UTCP_ARG_missing_UTCP_ARG',
          {'user_id': 'u1'},
        ),
        'ID=u1 X=UTCP_ARG_missing_UTCP_ARG',
      );
    });

    test('an argument cannot introduce a placeholder', () {
      expect(
        substituteArgumentPlaceholders('UTCP_ARG_a_UTCP_ARG', {
          'a': 'UTCP_ARG_b_UTCP_ARG',
          'b': 'secret',
        }),
        'UTCP_ARG_b_UTCP_ARG',
      );
    });

    test('escapes strings in a JSON-shaped template', () {
      const injection = '", "isAdmin": true, "x": "';
      for (final template in [
        '  {"q": "UTCP_ARG_q_UTCP_ARG"}',
        '\n["UTCP_ARG_q_UTCP_ARG"]',
      ]) {
        final decoded = jsonDecode(
          substituteArgumentPlaceholders(template, {'q': injection}),
        );
        expect(decoded, anyOf({'q': injection}, [injection]));
      }
    });

    test('jsonEscape overrides the detection', () {
      expect(
        substituteArgumentPlaceholders('{UTCP_ARG_q_UTCP_ARG}', {
          'q': 'a"b',
        }, jsonEscape: false),
        '{a"b}',
      );
      expect(
        substituteArgumentPlaceholders('q=UTCP_ARG_q_UTCP_ARG', {
          'q': 'a"b',
        }, jsonEscape: true),
        r'q=a\"b',
      );
    });
  });

  test('utcpDiscoveryMessage is spelled as the Python SDK sends it', () {
    expect(utcpDiscoveryMessage, '{"type": "utcp"}');
  });
}
