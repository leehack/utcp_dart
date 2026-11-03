import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/src/message.dart';
import 'package:utcp_socket/utcp_socket.dart';

void main() {
  const json = UdpCallTemplate(host: 'h', port: 1);
  UdpCallTemplate text([String? template]) => UdpCallTemplate(
    host: 'h',
    port: 1,
    requestDataFormat: RequestDataFormat.text,
    requestDataTemplate: template,
  );

  group('formatRequest', () {
    test('json sends the arguments as one object', () {
      final request = formatRequest({'a': 1, 'b': 'x', 'c': null}, json);
      expect(jsonDecode(request), {'a': 1, 'b': 'x', 'c': null});
    });

    test('text substitutes placeholders: strings raw, others as JSON', () {
      expect(
        formatRequest(
          {
            'cmd': 'SET',
            'value': 25,
            'on': true,
            'tags': ['a'],
          },
          text(
            'UTCP_ARG_cmd_UTCP_ARG UTCP_ARG_value_UTCP_ARG '
            'UTCP_ARG_on_UTCP_ARG UTCP_ARG_tags_UTCP_ARG UTCP_ARG_cmd_UTCP_ARG',
          ),
        ),
        'SET 25 true ["a"] SET',
      );
    });

    test('names with underscores and unknown placeholders', () {
      expect(
        formatRequest({
          'user_id': 'u1',
        }, text('ID=UTCP_ARG_user_id_UTCP_ARG X=UTCP_ARG_missing_UTCP_ARG')),
        'ID=u1 X=UTCP_ARG_missing_UTCP_ARG',
      );
    });

    test('an argument cannot inject a placeholder for another', () {
      expect(
        formatRequest({
          'a': 'UTCP_ARG_b_UTCP_ARG',
          'b': 'secret',
        }, text('UTCP_ARG_a_UTCP_ARG')),
        'UTCP_ARG_b_UTCP_ARG',
      );
    });

    test('a JSON-shaped text template escapes string arguments', () {
      final request = formatRequest({
        'q': '", "isAdmin": true, "x": "',
      }, text('{"q": "UTCP_ARG_q_UTCP_ARG"}'));
      expect(jsonDecode(request), {'q': '", "isAdmin": true, "x": "'});
    });

    test('text without a template joins the values as Python str()', () {
      expect(
        formatRequest({
          'a': 'x',
          'b': 2,
          'c': false,
          'd': null,
          'e': 1.0,
          'f': ['y', true],
          'g': {'k': 'v'},
        }, text()),
        "x 2 False None 1.0 ['y', True] {'k': 'v'}",
      );
      expect(formatRequest({'a': 'x'}, text('')), 'x');
    });
  });

  group('decodeResponse', () {
    final bytes = Uint8List.fromList(utf8.encode('héllo'));

    test('decodes with the configured encoding', () {
      expect(decodeResponse(bytes, 'utf-8'), 'héllo');
      expect(decodeResponse(bytes, 'UTF8'), 'héllo');
      expect(decodeResponse(bytes, 'utf_8'), 'héllo');
      expect(decodeResponse(Uint8List.fromList([0xe9]), 'latin1'), 'é');
      expect(decodeResponse(Uint8List.fromList([104, 105]), 'ascii'), 'hi');
      expect(decodeResponse(Uint8List.fromList([0xe9]), 'latin-1'), 'é');
      expect(decodeResponse(Uint8List.fromList([0x80]), 'cp1252'), '€');
      expect(
        decodeResponse(Uint8List.fromList([0xff, 0xfe, 0x61, 0]), 'utf-16'),
        'a',
      );
    });

    test('returns raw bytes when unset or undecodable', () {
      expect(decodeResponse(bytes, null), same(bytes));
      expect(decodeResponse(bytes, 'ascii'), same(bytes));
      final invalid = Uint8List.fromList([0xff, 0xfe]);
      expect(decodeResponse(invalid, 'utf-8'), same(invalid));
    });

    test('rejects unknown encodings', () {
      expect(
        () => decodeResponse(bytes, 'klingon'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('Supported: utf-8'),
          ),
        ),
      );
    });
  });
}
