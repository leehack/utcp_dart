@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/local_http_server.dart';

void main() {
  late LocalHttpServer server;
  late UtcpClient client;

  JsonMap manual(String base) => {
    'utcp_version': '1.0.1',
    'tools': [
      {
        'name': 'get_user',
        'tags': ['users'],
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$base/users/{id}',
          'header_fields': ['X-Trace'],
          'auth': {'auth_type': 'api_key', 'api_key': r'${KEY}'},
        },
      },
      {
        'name': 'create_user',
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$base/users',
          'http_method': 'POST',
          'auth': {
            'auth_type': 'oauth2',
            'token_url': '$base/token',
            'client_id': 'id',
            'client_secret': r'${SECRET}',
          },
        },
      },
      {
        'name': 'moved',
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$base/old',
        },
      },
      {
        'name': 'fail',
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$base/fail',
        },
      },
      {
        'name': 'slow',
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$base/slow',
        },
      },
    ],
  };

  setUp(() async {
    server = await LocalHttpServer.start((request, body) async {
      switch (request.uri.path) {
        case '/utcp':
          request.response.json(manual(server.baseUrl));
        case '/token':
          request.response.json({'access_token': 'tok', 'expires_in': 60});
        case '/old':
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/new');
        case '/new':
          request.response.json({'redirected': true});
        case '/fail':
          request.response.json({'detail': 'broken'}, status: 500);
        case '/slow':
          await Future<void>.delayed(const Duration(milliseconds: 300));
          request.response.write('late');
        default:
          request.response.json({
            'method': request.method,
            'path': request.uri.path,
            'query': request.uri.queryParameters,
            'key': request.headers.value('x-api-key'),
            'trace': request.headers.value('x-trace'),
            'authorization': request.headers.value('authorization'),
            'body': body.isEmpty ? null : jsonDecode(body),
          });
      }
    });
    client = await UtcpClient.create(
      config: UtcpClientConfig(
        variables: const {'api_KEY': 'k', 'api_SECRET': 's'},
        environment: const {},
        manualCallTemplates: [
          HttpCallTemplate(name: 'api', url: '${server.baseUrl}/utcp'),
        ],
      ),
      protocols: [
        HttpCommunicationProtocol(timeout: const Duration(milliseconds: 150)),
      ],
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('discovers the manual over HTTP', () async {
    expect((await client.getTools()).map((t) => t.name), [
      'api.get_user',
      'api.create_user',
      'api.moved',
      'api.fail',
      'api.slow',
    ]);
  });

  test(
    'maps path, query and header arguments and applies an API key',
    () async {
      expect(
        await client.callTool('api.get_user', {
          'id': '42',
          'X-Trace': 't-1',
          'expand': true,
        }),
        {
          'method': 'GET',
          'path': '/users/42',
          'query': {'expand': 'true'},
          'key': 'k',
          'trace': 't-1',
          'authorization': null,
          'body': null,
        },
      );
    },
  );

  test(
    'sends a JSON body with an OAuth2 token fetched from the server',
    () async {
      final result = await client.callTool('api.create_user', {
        'body': {'name': 'Ada'},
      });
      expect(result, containsPair('authorization', 'Bearer tok'));
      expect(result, containsPair('body', {'name': 'Ada'}));
      await client.callTool('api.create_user', {'body': {}});
      expect(
        server.requests.where((r) => r.uri.path == '/token'),
        hasLength(1),
      );
      expect(
        server.requests.firstWhere((r) => r.uri.path == '/token').body,
        contains('client_secret=s'),
      );
    },
  );

  test('a GET sends its body to the server', () async {
    const query = {'query': 'match_all'};
    final result = await client.callTool('api.get_user', {
      'id': '42',
      'body': query,
    });
    expect(result, containsPair('method', 'GET'));
    expect(result, containsPair('body', query));
  });

  test('follows same-origin redirects', () async {
    expect(await client.callTool('api.moved'), {'redirected': true});
  });

  test('surfaces server errors and timeouts', () async {
    await expectLater(
      client.callTool('api.fail'),
      throwsA(
        isA<UtcpHttpException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', contains('broken')),
      ),
    );
    await expectLater(
      client.callTool('api.slow'),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('Timed out'),
        ),
      ),
    );
  });

  test('YAML manuals are discovered by content type', () async {
    final yamlServer = await LocalHttpServer.start((request, _) {
      request.response
        ..headers.contentType = ContentType('application', 'yaml')
        ..write(
          'utcp_version: "1.0.1"\ntools:\n  - name: ping\n    tool_call_template:\n'
          '      call_template_type: http\n      url: http://localhost:1/ping\n',
        );
    });
    addTearDown(yamlServer.close);
    final result = await client.registerManual(
      HttpCallTemplate(name: 'yaml', url: '${yamlServer.baseUrl}/manual'),
    );
    expect(result.manual.tools.single.name, 'yaml.ping');
  });
}
