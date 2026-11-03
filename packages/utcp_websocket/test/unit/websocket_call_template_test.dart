import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

void main() {
  test('defaults match the Python reference', () {
    final t = WebSocketCallTemplate.fromJson({
      'call_template_type': 'websocket',
      'url': 'wss://api.example.com/ws',
    });
    expect(t.message, isNull);
    expect(t.protocol, isNull);
    expect(t.keepAlive, isTrue);
    expect(t.responseFormat, isNull);
    expect(t.timeout, const Duration(seconds: 30));
    expect(t.headers, isEmpty);
    expect(t.headerFields, isEmpty);
    expect(t.auth, isNull);
  });

  test('round-trips through toJson and the registry', () {
    final json = {
      'name': 'ws',
      'call_template_type': 'websocket',
      'auth': {
        'auth_type': 'api_key',
        'api_key': 'k',
        'var_name': 'Authorization',
        'location': 'header',
      },
      'allowed_communication_protocols': ['websocket'],
      'url': 'wss://api.example.com/ws',
      'message': {
        'type': 'UTCP_ARG_type_UTCP_ARG',
        'list': ['UTCP_ARG_a_UTCP_ARG', 1],
      },
      'protocol': 'utcp-v1',
      'keep_alive': false,
      'response_format': 'json',
      'timeout': 60,
      'headers': {'X-Custom': 'value'},
      'header_fields': ['user_id'],
    };
    final t = WebSocketCallTemplate.fromJson(json);
    expect(t.toJson(), json);
    final parse = WebSocketCommunicationProtocol()
        .callTemplateTypes[WebSocketCallTemplate.type]!;
    expect(parse(t.toJson()).toJson(), json);
  });

  test('string message templates and every response format', () {
    for (final format in WebSocketResponseFormat.values) {
      final t = WebSocketCallTemplate.fromJson({
        'url': 'wss://x/ws',
        'message': 'CMD:UTCP_ARG_command_UTCP_ARG',
        'response_format': format.name,
      });
      expect(t.message, 'CMD:UTCP_ARG_command_UTCP_ARG');
      expect(t.responseFormat, format);
    }
  });

  group('url security is checked when parsing', () {
    for (final url in [
      'wss://api.example.com/ws',
      'WSS://api.example.com/ws',
      'ws://localhost:8080/ws',
      'ws://127.0.0.1/ws',
      'ws://[::1]:9000/ws',
      // Variables are filled in later; the connection checks the result.
      r'wss://${HOST}/ws',
      r'ws://localhost:${PORT}/ws',
      r'ws://localhost:$PORT/ws',
    ]) {
      test('accepts $url', () {
        expect(WebSocketCallTemplate.fromJson({'url': url}).url, url);
      });
    }

    for (final url in [
      'ws://api.example.com/ws',
      'ws://localhost.evil.com/ws',
      'ws://127.0.0.1.attacker.example/ws',
      'http://localhost/ws',
      'https://api.example.com/ws',
      'wss:///ws',
      'not a url',
      '',
      r'ws://${HOST}/ws',
      r'${WS_URL}',
    ]) {
      test('rejects $url', () {
        expect(
          () => WebSocketCallTemplate.fromJson({'url': url}),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("Field 'url'"),
            ),
          ),
        );
      });
    }
  });

  for (final (field, value) in [
    ('message', 42),
    ('message', ['a']),
    ('response_format', 'xml'),
    ('timeout', 0),
    ('timeout', 'soon'),
    ('keep_alive', 'yes'),
    ('headers', {'X': 1}),
    ('header_fields', 'user_id'),
    ('auth', {'auth_type': 'unknown'}),
  ]) {
    test('rejects $field = $value', () {
      expect(
        () =>
            WebSocketCallTemplate.fromJson({'url': 'wss://x/ws', field: value}),
        throwsFormatException,
      );
    });
  }

  test('requires url', () {
    expect(
      () => WebSocketCallTemplate.fromJson({'call_template_type': 'websocket'}),
      throwsFormatException,
    );
  });

  test('is registered as a call template by the client', () async {
    final client = await UtcpClient.fromJson(
      {'manual_call_templates': <Object?>[]},
      protocols: [WebSocketCommunicationProtocol()],
    );
    addTearDown(client.close);
    expect(
      CallTemplate.fromJson({
        'call_template_type': 'websocket',
        'url': 'wss://x/ws',
      }),
      isA<WebSocketCallTemplate>(),
    );
  });
}
