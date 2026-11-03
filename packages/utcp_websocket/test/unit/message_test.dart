import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp_websocket/src/message.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

void main() {
  group('formatMessage', () {
    test('without a template sends the arguments as JSON', () {
      expect(jsonDecode(formatMessage(null, {'foo': 'bar', 'baz': 123})), {
        'foo': 'bar',
        'baz': 123,
      });
    });

    test('string templates substitute strings raw and others as JSON', () {
      expect(
        formatMessage(
          'CMD:UTCP_ARG_command_UTCP_ARG;DEVICE:UTCP_ARG_device_id_UTCP_ARG;'
          'VALUE:UTCP_ARG_value_UTCP_ARG;MISSING:UTCP_ARG_x_UTCP_ARG',
          {'command': 'SET_TEMP', 'device_id': 'dev123', 'value': 25},
        ),
        'CMD:SET_TEMP;DEVICE:dev123;VALUE:25;MISSING:UTCP_ARG_x_UTCP_ARG',
      );
      expect(
        formatMessage('GET /x?q=UTCP_ARG_q_UTCP_ARG', {'q': 'a"b'}),
        'GET /x?q=a"b',
      );
    });

    test('a JSON-shaped string template escapes string arguments', () {
      final message = formatMessage('  {"q": "UTCP_ARG_q_UTCP_ARG"}', {
        'q': '", "isAdmin": true, "x": "',
      });
      expect(jsonDecode(message), {'q': '", "isAdmin": true, "x": "'});
      expect(
        jsonDecode(formatMessage('["UTCP_ARG_q_UTCP_ARG"]', {'q': r'a\"'})),
        [r'a\"'],
      );
    });

    test('object templates are substituted recursively, then encoded', () {
      final message = formatMessage(
        {
          'jsonrpc': '2.0',
          'method': 'UTCP_ARG_method_UTCP_ARG',
          'params': 'UTCP_ARG_params_UTCP_ARG',
          'id': 1,
          'data': {
            'commands': ['UTCP_ARG_cmd_UTCP_ARG', 'fixed'],
            'quote': 'UTCP_ARG_q_UTCP_ARG',
          },
        },
        {
          'method': 'getUser',
          'params': {'id': 123},
          'cmd': 'go',
          'q': '", "isAdmin": true, "x": "',
        },
      );
      expect(jsonDecode(message), {
        'jsonrpc': '2.0',
        'method': 'getUser',
        // A non-string argument inside a string leaf is stringified JSON,
        // as in the Python transport.
        'params': '{"id":123}',
        'id': 1,
        'data': {
          'commands': ['go', 'fixed'],
          'quote': '", "isAdmin": true, "x": "',
        },
      });
    });

    test('an argument cannot inject a placeholder for another', () {
      expect(
        formatMessage('UTCP_ARG_a_UTCP_ARG', {
          'a': 'UTCP_ARG_b_UTCP_ARG',
          'b': 'x',
        }),
        'UTCP_ARG_b_UTCP_ARG',
      );
    });
  });

  group('decodeMessage', () {
    test('parses JSON only when asked', () {
      expect(decodeMessage('{"a":1}', WebSocketResponseFormat.json), {'a': 1});
      expect(decodeMessage('{"a":1}', WebSocketResponseFormat.text), '{"a":1}');
      expect(decodeMessage('{"a":1}', WebSocketResponseFormat.raw), '{"a":1}');
      expect(decodeMessage('{"a":1}', null), '{"a":1}');
    });

    test('returns text that is not JSON as is', () {
      expect(decodeMessage('plain', WebSocketResponseFormat.json), 'plain');
    });

    test('returns binary frames as bytes', () {
      final bytes = decodeMessage([1, 2], WebSocketResponseFormat.json);
      expect(bytes, isA<Uint8List>());
      expect(bytes, [1, 2]);
    });
  });
}
