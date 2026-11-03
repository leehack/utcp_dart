import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/src/http/security.dart' show isLoopbackHost;
import 'package:utcp/utcp.dart';

const manualUrl = 'https://api.example.com/utcp';

Map<String, dynamic> manualJson({List<Map<String, dynamic>>? tools}) => {
  'utcp_version': '1.0.0',
  'manual_version': '1.0.0',
  'tools':
      tools ??
      [
        {
          'name': 'get_weather',
          'description': 'Get current weather for a city',
          'tags': ['weather', 'forecast'],
          'inputs': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
          },
          'tool_call_template': {
            'call_template_type': 'http',
            'url': 'https://api.example.com/weather/{city}',
            'http_method': 'GET',
            'auth': {'auth_type': 'api_key', 'api_key': r'${API_KEY}', 'var_name': 'X-Api-Key'},
          },
        },
        {
          'name': 'create_note',
          'description': 'Create a note',
          'tags': ['notes'],
          'tool_call_template': {
            'call_template_type': 'http',
            'url': 'https://api.example.com/notes',
            'http_method': 'POST',
            'header_fields': ['X-Request-Id'],
          },
        },
      ],
};

http.Response jsonResponse(
  Object body, [
  int status = 200,
  Map<String, String> headers = const {},
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Future<UtcpClient> clientWith(
  MockClientHandler handler, {
  Map<String, String> variables = const {},
  List<CallTemplate>? manuals,
}) => UtcpClient.create(
  config: UtcpClientConfig(
    variables: variables,
    environment: const {},
    manualCallTemplates: manuals ?? [const HttpCallTemplate(name: 'weather-api', url: manualUrl)],
  ),
  protocols: {'http': HttpCommunicationProtocol(httpClient: MockClient(handler))},
);

void main() {
  group('models', () {
    test('manual round-trips through JSON', () {
      final manual = UtcpManual.fromJson(manualJson());
      final again = UtcpManual.fromJson(jsonDecode(jsonEncode(manual.toJson())));
      expect(again.tools.map((t) => t.name), ['get_weather', 'create_note']);
      final template = again.tools.first.toolCallTemplate as HttpCallTemplate;
      expect(template.url, 'https://api.example.com/weather/{city}');
      expect((template.auth as ApiKeyAuth).varName, 'X-Api-Key');
      expect(template.bodyField, 'body');
    });

    test('unknown call_template_type is rejected', () {
      expect(
        () => CallTemplate.fromJson({'call_template_type': 'carrier_pigeon'}),
        throwsFormatException,
      );
    });

    test('custom auth types can be registered', () {
      expect(Auth.register('api_key', ApiKeyAuth.fromJson), isFalse);
    });
  });

  group('variables', () {
    test('namespaced lookup doubles underscores in the manual name', () async {
      const s = VariableSubstitutor(variables: {'my__api_TOKEN': 't0k'}, environment: {});
      expect(await s.substitute(r'Bearer ${TOKEN}', namespace: 'my_api'), 'Bearer t0k');
      expect(s.findRequiredVariables({'a': r'$TOKEN', 'b': r'${X}'}, namespace: 'my_api'), [
        'my__api_TOKEN',
        'my__api_X',
      ]);
    });

    test(r'strings with $ref are left untouched', () async {
      const s = VariableSubstitutor(environment: {});
      expect(await s.substitute(r'#/$ref/${NOPE}'), r'#/$ref/${NOPE}');
    });

    test('precedence is config, loaders, environment', () async {
      final s = VariableSubstitutor(
        variables: const {'A': 'config'},
        loaders: [
          _MapLoader(const {'A': 'loader', 'B': 'loader'}),
        ],
        environment: const {'A': 'env', 'B': 'env', 'C': 'env'},
      );
      expect(await s.substitute([r'$A', r'$B', r'$C']), ['config', 'loader', 'env']);
    });

    test('missing variables throw', () async {
      const s = VariableSubstitutor(environment: {});
      expect(s.substitute(r'${MISSING}'), throwsA(isA<UtcpVariableNotFoundException>()));
    });
  });

  group('client over HTTP', () {
    test('registers a manual, prefixes tool names, and calls a tool with auth', () async {
      final requests = <http.Request>[];
      final client = await clientWith((request) async {
        requests.add(request);
        if (request.url.toString() == manualUrl) return jsonResponse(manualJson());
        return jsonResponse({'temp': 21, 'city': request.url.pathSegments.last});
      }, variables: {'weather__api_API_KEY': 'secret'});

      final tools = await client.getTools();
      expect(tools.map((t) => t.name), ['weather_api.get_weather', 'weather_api.create_note']);

      final result = await client.callTool('weather_api.get_weather', {
        'city': 'São Paulo',
        'units': 'metric',
      });
      expect(result, {'temp': 21, 'city': 'São Paulo'});

      final call = requests.last;
      expect(call.method, 'GET');
      expect(call.url.path, '/weather/S%C3%A3o%20Paulo');
      expect(call.url.queryParameters, {'units': 'metric'});
      expect(call.headers['X-Api-Key'], 'secret');
      await client.close();
    });

    test('maps body and header fields', () async {
      late http.Request call;
      final client = await clientWith((request) async {
        if (request.url.toString() == manualUrl) return jsonResponse(manualJson());
        call = request;
        return http.Response('created', 201);
      });

      final result = await client.callTool('weather_api.create_note', {
        'X-Request-Id': 'abc',
        'body': {'text': 'hi'},
      });
      expect(result, 'created');
      expect(call.method, 'POST');
      expect(call.headers['X-Request-Id'], 'abc');
      expect(call.headers['Content-Type'], 'application/json');
      expect(jsonDecode(call.body), {'text': 'hi'});
      expect(call.url.query, isEmpty);
    });

    test('HTTP errors surface as UtcpHttpException with the server reason', () async {
      final client = await clientWith((request) async {
        if (request.url.toString() == manualUrl) return jsonResponse(manualJson());
        return jsonResponse({'error': 'quota exceeded'}, 429);
      }, variables: {'weather__api_API_KEY': 'k'});

      expect(
        client.callTool('weather_api.get_weather', {'city': 'x'}),
        throwsA(
          isA<UtcpHttpException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.message, 'message', contains('quota exceeded')),
        ),
      );
    });

    test('a failed discovery is reported, not thrown', () async {
      final client = await clientWith((_) async => http.Response('nope', 500));
      expect(await client.getTools(), isEmpty);
      final result = await client.registerManual(
        const HttpCallTemplate(name: 'other', url: manualUrl),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('HTTP 500'));
    });

    test('YAML manuals are accepted', () async {
      final client = await clientWith(
        (_) async => http.Response(
          '''
utcp_version: "1.0.0"
tools:
  - name: ping
    tool_call_template:
      call_template_type: http
      url: https://api.example.com/ping
''',
          200,
          headers: {'content-type': 'application/yaml'},
        ),
      );
      expect((await client.getTools()).single.name, 'weather_api.ping');
    });

    test('tools using a protocol the manual does not allow are dropped', () async {
      CallTemplate.register('fake', _FakeTemplate.fromJson);
      final client = await clientWith(
        (_) async => jsonResponse(
          manualJson(
            tools: [
              {
                'name': 'sneaky',
                'tool_call_template': {'call_template_type': 'fake'},
              },
            ],
          ),
        ),
      );
      expect(await client.getTools(), isEmpty);
    });

    test('search ranks by name, tags, and description', () async {
      final client = await clientWith((_) async => jsonResponse(manualJson()));
      final results = await client.searchTools('weather forecast');
      expect(results.first.name, 'weather_api.get_weather');
      expect(await client.searchTools('x', anyOfTagsRequired: ['notes']), hasLength(1));
    });
  });

  group('security', () {
    test('loopback detection covers the forms named in the spec', () {
      for (final host in [
        'localhost',
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
      for (final host in ['example.com', '128.0.0.1', '10.0.0.1', '::2', '1.2.3.4']) {
        expect(isLoopbackHost(host), isFalse, reason: host);
      }
    });

    test('redirects from a remote origin into loopback are refused', () async {
      final client = await clientWith((request) async {
        if (request.url.toString() == manualUrl) return jsonResponse(manualJson());
        return http.Response('', 302, headers: {'location': 'https://127.0.0.2/admin'});
      }, variables: {'weather__api_API_KEY': 'k'});
      expect(
        client.callTool('weather_api.get_weather', {'city': 'x'}),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('https to a non-literal loopback address is still treated as loopback', () async {
      final client = await clientWith(
        (_) async => jsonResponse(
          manualJson(
            tools: [
              {
                'name': 'fetch',
                'tool_call_template': {'call_template_type': 'http', 'url': 'https://{host}/x'},
              },
            ],
          ),
        ),
      );
      expect(
        client.callTool('weather_api.fetch', {'host': '127.0.0.2'}),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('the timeout covers the whole request', () async {
      final protocol = HttpCommunicationProtocol(
        httpClient: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 50),
      );
      final client = await UtcpClient.create(protocols: {'http': protocol});
      expect(
        protocol.callTool(client, 't', {}, const HttpCallTemplate(url: 'https://a.example/x')),
        throwsA(isA<UtcpException>().having((e) => e.message, 'message', contains('Timed out'))),
      );
    });

    test('plain HTTP to a remote host is rejected', () async {
      final client = await clientWith(
        (_) async => fail('no request expected'),
        manuals: [const HttpCallTemplate(name: 'm', url: 'http://api.example.com/utcp')],
      );
      expect(await client.getTools(), isEmpty);
    });

    test('a remote manual may not declare loopback tool URLs', () async {
      final client = await clientWith(
        (_) async => jsonResponse(
          manualJson(
            tools: [
              {
                'name': 'admin',
                'tool_call_template': {
                  'call_template_type': 'http',
                  'url': 'http://localhost:8080/admin',
                },
              },
            ],
          ),
        ),
      );
      expect(await client.getTools(), isEmpty);
    });

    test('path arguments cannot redirect a call onto loopback', () async {
      final client = await clientWith(
        (request) async => jsonResponse(
          manualJson(
            tools: [
              {
                'name': 'fetch',
                'tool_call_template': {'call_template_type': 'http', 'url': '{url}'},
              },
            ],
          ),
        ),
      );
      expect(
        client.callTool('weather_api.fetch', {'url': 'http://127.0.0.1:9000/secrets'}),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('auth headers are dropped on cross-origin redirects', () async {
      final seen = <String, Map<String, String>>{};
      final client = await clientWith((request) async {
        if (request.url.toString() == manualUrl) return jsonResponse(manualJson());
        seen[request.url.host] = request.headers;
        if (request.url.host == 'api.example.com') {
          return http.Response('', 302, headers: {'location': 'https://evil.example.net/x'});
        }
        return jsonResponse({'ok': true});
      }, variables: {'weather__api_API_KEY': 'secret'});

      expect(await client.callTool('weather_api.get_weather', {'city': 'x'}), {'ok': true});
      expect(seen['api.example.com']!['X-Api-Key'], 'secret');
      expect(seen['evil.example.net']!.containsKey('X-Api-Key'), isFalse);
    });
  });

  group('oauth2', () {
    test('client-credentials tokens are fetched once and cached', () async {
      var tokenRequests = 0;
      final client = await clientWith((request) async {
        if (request.url.path == '/token') {
          tokenRequests++;
          expect(request.bodyFields['grant_type'], 'client_credentials');
          return jsonResponse({'access_token': 'tok', 'expires_in': 3600});
        }
        if (request.url.toString() == manualUrl) {
          return jsonResponse(
            manualJson(
              tools: [
                {
                  'name': 'me',
                  'tool_call_template': {
                    'call_template_type': 'http',
                    'url': 'https://api.example.com/me',
                    'auth': {
                      'auth_type': 'oauth2',
                      'token_url': 'https://api.example.com/token',
                      'client_id': 'id',
                      'client_secret': 'secret',
                    },
                  },
                },
              ],
            ),
          );
        }
        return jsonResponse({'auth': request.headers['Authorization']});
      });

      await Future.wait([client.callTool('weather_api.me'), client.callTool('weather_api.me')]);
      expect(await client.callTool('weather_api.me'), {'auth': 'Bearer tok'});
      expect(tokenRequests, 1);
    });
  });
}

class _MapLoader implements VariableLoader {
  _MapLoader(this.values);

  final Map<String, String> values;

  @override
  String? get(String key) => values[key];
}

class _FakeTemplate extends CallTemplate {
  const _FakeTemplate({super.name});

  factory _FakeTemplate.fromJson(JsonMap json) => _FakeTemplate(name: json['name'] as String?);

  @override
  String get callTemplateType => 'fake';

  @override
  JsonMap toJson() => baseJson();
}
