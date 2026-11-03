@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/local_http_server.dart';
import '../support/openapi_fixtures.dart';

void main() {
  late LocalHttpServer server;
  late UtcpClient client;

  setUp(() async {
    server = await LocalHttpServer.start((request, body) {
      switch (request.uri.path) {
        case '/specs/openapi.json':
          // Relative to the document: tools live under /api.
          request.response.json(petstoreOpenApi3(serverUrl: '../api'));
        case '/swagger.yaml':
          request.response
            ..headers.contentType = ContentType('application', 'yaml')
            ..write(petstoreSwaggerYaml());
        case '/oauth/token':
          request.response.json({'access_token': 'tok', 'expires_in': 60});
        default:
          request.response.json({
            'method': request.method,
            'path': request.uri.path,
            'query': request.uri.queryParameters,
            'key': request.headers.value('x-api-key'),
            'trace': request.headers.value('x-trace-id'),
            'authorization': request.headers.value('authorization'),
            'body': body.isEmpty ? null : jsonDecode(body),
          });
      }
    });
    client = await UtcpClient.create(
      config: UtcpClientConfig(
        variables: const {
          'petstore_CLIENT_ID_2': 'id',
          'petstore_CLIENT_SECRET_2': 'secret',
          'v2_USERNAME_0': 'user',
          'v2_PASSWORD_0': 'pass',
        },
        environment: const {},
        manualCallTemplates: [
          HttpCallTemplate(
            name: 'petstore',
            url: '${server.baseUrl}/specs/openapi.json',
            authTools: const ApiKeyAuth(apiKey: 'k'),
          ),
          HttpCallTemplate(name: 'v2', url: '${server.baseUrl}/swagger.yaml'),
        ],
      ),
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('an OpenAPI 3 spec is discovered and its tools called', () async {
    expect(
      (await client.getTools()).map((t) => t.name),
      containsAll([
        'petstore.listPets',
        'petstore.createPet',
        'petstore.showPetById',
        'petstore.deletePet',
      ]),
    );

    expect(await client.callTool('petstore.showPetById', {'petId': 'p/1'}), {
      'method': 'GET',
      'path': '/api/pets/p%2F1',
      'query': <String, Object?>{},
      'key': 'k',
      'trace': null,
      'authorization': null,
      'body': null,
    });
    expect(
      await client.callTool('petstore.listPets', {
        'limit': 5,
        'X-Trace-Id': 't-1',
      }),
      allOf(
        containsPair('query', {'limit': '5'}),
        containsPair('trace', 't-1'),
        containsPair('key', null),
      ),
    );
    expect(
      await client.callTool('petstore.createPet', {
        'body': {'name': 'Rex'},
      }),
      allOf(
        containsPair('method', 'POST'),
        containsPair('body', {'name': 'Rex'}),
      ),
    );
  });

  test('OAuth2 with a token URL relative to the spec', () async {
    final result = await client.callTool('petstore.deletePet', {'petId': '1'});
    expect(result, containsPair('authorization', 'Bearer tok'));
    final token = server.requests.singleWhere(
      (r) => r.uri.path == '/oauth/token',
    );
    expect(token.body, contains('client_secret=secret'));
    expect(token.body, contains('scope=write%3Apets+read%3Apets'));
  });

  test('a YAML Swagger spec is served from the host of the document', () async {
    final result = await client.callTool('v2.addPet', {
      'body': {'name': 'doggie'},
    });
    expect(result, containsPair('path', '/v2/pet'));
    expect(
      result,
      containsPair(
        'authorization',
        'Basic ${base64Encode(utf8.encode('user:pass'))}',
      ),
    );
  });
}
