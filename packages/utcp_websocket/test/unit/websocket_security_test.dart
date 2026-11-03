import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

void main() {
  setUpAll(
    () => CallTemplate.registry.register(
      WebSocketCallTemplate.type,
      WebSocketCallTemplate.fromJson,
    ),
  );

  test('wss anywhere, plain ws only to loopback', () {
    for (final url in [
      'wss://api.example.com/socket',
      'WSS://api.example.com/socket',
      'ws://localhost/socket',
      'ws://127.0.0.1:9090/socket',
      'ws://[::1]:9090/socket',
      'ws://127.1/socket',
      'ws://localhost./socket',
    ]) {
      expect(isSecureWebSocketUrl(url), isTrue, reason: url);
      ensureSecureWebSocketUrl(url, 'test');
    }
    for (final url in [
      'ws://169.254.169.254/socket',
      'ws://internal.service.local/socket',
      'ws://10.0.0.5/socket',
      'ws://example.com/socket',
      'ws://localhost.evil.com/socket',
      'ws://127.0.0.1.attacker.example/socket',
      'http://localhost/socket',
      'https://api.example.com/socket',
      '',
      'not-a-url',
      'javascript:alert(1)',
      'wss://',
      'ws://[::1',
    ]) {
      expect(isSecureWebSocketUrl(url), isFalse, reason: url);
      expect(
        () => ensureSecureWebSocketUrl(url, 'test'),
        throwsA(
          isA<UtcpSecurityException>().having(
            (e) => e.message,
            'message',
            contains('WebSocket URL'),
          ),
        ),
        reason: url,
      );
    }
  });

  group('a manual discovered from a remote origin', () {
    final remote = Uri.parse('wss://tools.example.com/ws');

    UtcpManual manual(JsonMap callTemplate) => UtcpManual.fromJson({
      'utcp_version': '1.0.1',
      'tools': [
        {'name': 't', 'tool_call_template': callTemplate},
      ],
    });

    for (final (label, template) in [
      (
        'a ws tool',
        {'call_template_type': 'websocket', 'url': 'ws://localhost:1/ws'},
      ),
      (
        'a wss tool',
        {'call_template_type': 'websocket', 'url': 'wss://127.0.0.1/ws'},
      ),
      (
        'an OAuth2 token URL',
        {
          'call_template_type': 'websocket',
          'url': 'wss://tools.example.com/ws',
          'auth': {
            'auth_type': 'oauth2',
            'token_url': 'http://localhost:9000/token',
            'client_id': 'id',
            'client_secret': 'secret',
          },
        },
      ),
      (
        'an http tool',
        {'call_template_type': 'http', 'url': 'http://127.0.0.1/x'},
      ),
    ]) {
      test('may not point $label at loopback', () {
        expect(
          () => rejectRemoteLoopbackWebSocketTools(
            remote,
            manual(template),
            'manual discovery',
          ),
          throwsA(isA<UtcpSecurityException>()),
        );
      });
    }

    test('may point tools at remote hosts', () {
      rejectRemoteLoopbackWebSocketTools(
        remote,
        manual({
          'call_template_type': 'websocket',
          'url': 'wss://other.example.com/ws',
        }),
        'manual discovery',
      );
    });

    test('from loopback may point tools at loopback', () {
      rejectRemoteLoopbackWebSocketTools(
        Uri.parse('ws://localhost:8080/ws'),
        manual({
          'call_template_type': 'websocket',
          'url': 'ws://localhost:1/ws',
        }),
        'manual discovery',
      );
    });
  });
}
