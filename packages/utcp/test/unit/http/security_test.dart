import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

void main() {
  test('loopback detection covers the forms named in the spec', () {
    for (final host in [
      'localhost',
      'LOCALHOST.',
      '127.0.0.1',
      '127.8.9.10',
      '127.1',
      '0x7f000001',
      '2130706433',
      '0.0.0.0',
      '::1',
      '[::1]',
      '::',
      '::ffff:127.0.0.1',
    ]) {
      expect(isLoopbackHost(host), isTrue, reason: host);
    }
    for (final host in [
      'example.com',
      '128.0.0.1',
      '10.0.0.1',
      '::2',
      '1.2.3.4',
      '08.0.0.1',
    ]) {
      expect(isLoopbackHost(host), isFalse, reason: host);
    }
  });

  test('only HTTPS or loopback HTTP is secure', () {
    expect(isSecureUrl('https://api.example.com/x'), isTrue);
    expect(isSecureUrl('http://localhost:8080/x'), isTrue);
    expect(isSecureUrl('http://127.0.0.5/x'), isTrue);
    expect(isSecureUrl('http://api.example.com/x'), isFalse);
    expect(isSecureUrl('ftp://api.example.com/x'), isFalse);
    expect(isSecureUrl('not a url'), isFalse);
    expect(
      () => ensureSecureUrl('http://api.example.com', 'test'),
      throwsA(isA<UtcpSecurityException>()),
    );
  });

  test('literal template hosts ignore placeholders', () {
    expect(
      literalTemplateHost('https://api.example.com:8443/{id}'),
      'api.example.com',
    );
    expect(literalTemplateHost('http://[::1]:80/x'), '::1');
    expect(literalTemplateHost('https://{host}/x'), isNull);
    expect(literalTemplateHost('/relative'), isNull);
  });

  test('a loopback destination must be declared by the template', () {
    ensureLoopbackWasDeclared(
      'http://localhost:{port}/x',
      'http://localhost:1/x',
      't',
    );
    expect(
      () => ensureLoopbackWasDeclared(
        'https://{host}/x',
        'https://127.0.0.2/x',
        't',
      ),
      throwsA(isA<UtcpSecurityException>()),
    );
  });

  test('a remote manual may not declare loopback tool or token URLs', () {
    UtcpManual manualWith(HttpCallTemplate template) => UtcpManual(
      tools: [Tool(name: 't', toolCallTemplate: template)],
    );
    final remote = Uri.parse('https://api.example.com/utcp');
    expect(
      () => rejectRemoteLoopbackToolUrls(
        remote,
        manualWith(const HttpCallTemplate(url: 'http://localhost:{port}/x')),
        't',
      ),
      throwsA(isA<UtcpSecurityException>()),
    );
    expect(
      () => rejectRemoteLoopbackToolUrls(
        remote,
        manualWith(
          const HttpCallTemplate(
            url: 'https://api.example.com/x',
            auth: OAuth2Auth(
              tokenUrl: 'http://127.0.0.1/token',
              clientId: 'i',
              clientSecret: 's',
            ),
          ),
        ),
        't',
      ),
      throwsA(isA<UtcpSecurityException>()),
    );
    rejectRemoteLoopbackToolUrls(
      Uri.parse('http://localhost/utcp'),
      manualWith(const HttpCallTemplate(url: 'http://localhost/x')),
      't',
    );
  });
}
