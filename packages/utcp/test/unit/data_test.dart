import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fixtures.dart';

void main() {
  test('a manual round-trips through JSON', () {
    final manual = UtcpManual.fromJson(manualJson());
    final again = UtcpManual.fromJson(
      jsonDecode(jsonEncode(manual.toJson())) as JsonMap,
    );
    expect(again.tools.map((t) => t.name), ['get_weather', 'create_note']);
    expect(again.tools.first.inputs.required, ['city']);
    final template = again.tools.first.toolCallTemplate as HttpCallTemplate;
    expect(template.url, 'https://api.example.com/weather/{city}');
    expect(template.httpMethod, HttpMethod.get);
    expect(template.bodyField, 'body');
    expect((template.auth! as ApiKeyAuth).varName, 'X-Api-Key');
  });

  test('manuals default to the spec version the package implements', () {
    expect(utcpProtocolVersion, '1.1.0');
    expect(const UtcpManual(tools: []).toJson()['utcp_version'], '1.1.0');
    expect(UtcpManual.fromJson({'tools': <Object?>[]}).utcpVersion, '1.1.0');
  });

  test('a manual without tools is rejected', () {
    expect(
      () => UtcpManual.fromJson({'utcp_version': '1.0.1'}),
      throwsFormatException,
    );
  });

  test('UtcpManual.isManual tells manuals from other documents', () {
    expect(UtcpManual.isManual(manualJson()), isTrue);
    expect(UtcpManual.isManual({'openapi': '3.0.0', 'paths': {}}), isFalse);
  });

  group('call templates', () {
    test('unknown call_template_type is rejected', () {
      expect(
        () => CallTemplate.fromJson({'call_template_type': 'carrier_pigeon'}),
        throwsFormatException,
      );
    });

    test('http_method is validated', () {
      expect(
        () => HttpCallTemplate.fromJson({
          'call_template_type': 'http',
          'url': 'https://a.example',
          'http_method': 'TRACE',
        }),
        throwsFormatException,
      );
    });

    test('allowed protocols default to the template type', () {
      expect(
        const HttpCallTemplate(url: 'https://a').effectiveAllowedProtocols,
        ['http'],
      );
      expect(
        const HttpCallTemplate(
          url: 'https://a',
          allowedCommunicationProtocols: ['http', 'cli'],
        ).effectiveAllowedProtocols,
        ['http', 'cli'],
      );
    });

    test('a null body_field disables the body mapping', () {
      final template = HttpCallTemplate.fromJson({
        'call_template_type': 'http',
        'url': 'https://a.example',
        'body_field': null,
      });
      expect(template.bodyField, isNull);
      expect(HttpCallTemplate.fromJson(template.toJson()).bodyField, isNull);
    });
  });

  group('auth', () {
    for (final auth in <Auth>[
      const ApiKeyAuth(apiKey: 'k', location: ApiKeyLocation.cookie),
      const BasicAuth(username: 'u', password: 'p'),
      const OAuth2Auth(
        tokenUrl: 'https://a/token',
        clientId: 'i',
        clientSecret: 's',
        scope: 'read',
      ),
      const OAuth2UserAuth(
        accessToken: 't',
        grantType: OAuth2UserGrantType.deviceCode,
      ),
    ]) {
      test('${auth.authType} round-trips', () {
        expect(Auth.fromJson(auth.toJson()).toJson(), auth.toJson());
      });
    }

    test('invalid enum values are rejected', () {
      expect(
        () => Auth.fromJson({
          'auth_type': 'api_key',
          'api_key': 'k',
          'location': 'body',
        }),
        throwsFormatException,
      );
      expect(
        () => Auth.fromJson({
          'auth_type': 'oauth2_user',
          'access_token': 't',
          'grant_type': 'password',
        }),
        throwsFormatException,
      );
    });
  });
}
