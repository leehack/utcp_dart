import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../support/fixtures.dart';
import '../../support/openapi_fixtures.dart';

void main() {
  group('OpenAPI discovery', () {
    const specUrl = 'https://petstore.example.com/openapi.json';
    final requests = <http.Request>[];

    setUp(requests.clear);

    Future<UtcpClient> petstoreClient(
      http.Response Function(http.Request request) spec, {
      Auth? authTools,
      Map<String, String> variables = const {},
    }) => mockedClient(
      (request) async {
        requests.add(request);
        if (request.url.path.endsWith('/openapi.json') ||
            request.url.path.endsWith('.yaml')) {
          return spec(request);
        }
        return jsonResponse({'id': 'p1', 'name': 'Rex'});
      },
      variables: variables,
      manuals: [
        HttpCallTemplate(
          name: 'petstore',
          url: specUrl,
          headers: const {'X-Client': 'utcp'},
          authTools: authTools,
        ),
      ],
    );

    for (final (configured, redirected, keeps) in [
      (
        'https://api.good.com/openapi.json',
        'https://evil.example/spec.json',
        false,
      ),
      (
        'https://api.good.com/openapi.json',
        'https://api.good.com:8443/spec.json',
        false,
      ),
      ('http://localhost:8080/openapi.json', 'https://localhost:8080/s', false),
      (
        'https://api.good.com/openapi.json',
        'https://api.good.com/v2/spec.json',
        true,
      ),
    ]) {
      test('a spec redirected to $redirected '
          '${keeps ? 'keeps' : 'gets no'} credentials', () async {
        final client = await mockedClient(
          (request) async => request.url == Uri.parse(configured)
              ? http.Response('', 302, headers: {'location': redirected})
              : jsonResponse(petstoreOpenApi3(serverUrl: '/v1')),
          manuals: [
            HttpCallTemplate(
              name: 'good',
              url: configured,
              headers: const {'Authorization': 'Bearer tok-9f2'},
              authTools: const ApiKeyAuth(apiKey: 'K123'),
              allowedCommunicationProtocols: const ['http'],
            ),
          ],
        );
        addTearDown(client.close);
        final tools = await client.getTools();
        expect(tools, isNotEmpty);
        final templates = [
          for (final tool in tools) tool.toolCallTemplate.toJson().toString(),
        ];
        expect(templates.every((t) => t.contains('tok-9f2')), keeps);
        expect(templates.any((t) => t.contains('K123')), keeps);
      });
    }

    test('a spec is converted and its tools call the API', () async {
      final client = await petstoreClient(
        (_) => jsonResponse(petstoreOpenApi3(serverUrl: '/v1')),
        authTools: const ApiKeyAuth(apiKey: 'secret'),
      );
      addTearDown(client.close);
      expect((await client.getTools()).map((t) => t.name), [
        'petstore.listPets',
        'petstore.createPet',
        'petstore.showPetById',
        'petstore.deletePet',
      ]);

      await client.callTool('petstore.createPet', {
        'body': {'name': 'Rex'},
      });
      final create = requests.last;
      expect(create.method, 'POST');
      expect(create.url.toString(), 'https://petstore.example.com/v1/pets');
      expect(create.headers['X-Api-Key'], 'secret');
      expect(create.headers['X-Client'], 'utcp');
      expect(create.body, '{"name":"Rex"}');

      await client.callTool('petstore.listPets', {
        'limit': 2,
        'X-Trace-Id': 't-1',
      });
      final list = requests.last;
      expect(
        list.url.toString(),
        'https://petstore.example.com/v1/pets?limit=2',
      );
      expect(list.headers['X-Trace-Id'], 't-1');
      expect(list.headers.containsKey('X-Api-Key'), isFalse);
    });

    test('generated auth placeholders resolve from manual variables', () async {
      final client = await petstoreClient(
        (_) => jsonResponse(petstoreOpenApi3()),
        variables: {'petstore_API_KEY_1': 'from-variables'},
      );
      addTearDown(client.close);
      await client.callTool('petstore.showPetById', {'petId': 'a b'});
      expect(
        requests.last.url.toString(),
        'https://petstore.example.com/v1/pets/a%20b',
      );
      expect(requests.last.headers['X-Api-Key'], 'from-variables');
      expect(
        client.callTool('petstore.createPet', {'body': {}}),
        throwsA(isA<UtcpVariableNotFoundException>()),
      );
    });

    test('YAML specs are parsed', () async {
      final client = await petstoreClient(
        (_) => http.Response(
          petstoreSwaggerYaml(host: 'petstore.example.com'),
          200,
          headers: {'content-type': 'application/yaml'},
        ),
      );
      addTearDown(client.close);
      expect((await client.getTools()).map((t) => t.name), [
        'petstore.addPet',
        'petstore.findPetsByStatus',
      ]);
    });

    test('a remote spec may not declare loopback servers', () async {
      final client = await petstoreClient(
        (_) => jsonResponse(petstoreOpenApi3(serverUrl: 'http://127.0.0.1')),
      );
      addTearDown(client.close);
      expect(await client.getTools(), isEmpty);
      final result = await client.registerManual(
        const HttpCallTemplate(name: 'again', url: specUrl),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('loopback'));
    });

    test('a malformed spec fails discovery with the field named', () async {
      final client = await petstoreClient(
        (_) => jsonResponse({
          'openapi': '3.0.0',
          'paths': {
            '/x': {
              'get': {'operationId': 'x', 'parameters': 'none'},
            },
          },
        }),
      );
      addTearDown(client.close);
      final result = await client.registerManual(
        const HttpCallTemplate(name: 'again', url: specUrl),
      );
      expect(result.success, isFalse);
      expect(
        result.errors.single,
        allOf(contains('GET /x'), contains("'parameters'")),
      );
    });

    test('a document that is neither a manual nor a spec fails', () async {
      final client = await petstoreClient((_) => jsonResponse({'hello': 1}));
      addTearDown(client.close);
      final result = await client.registerManual(
        const HttpCallTemplate(name: 'again', url: specUrl),
      );
      expect(result.errors.single, contains('neither a UTCP manual'));
    });
  });
}
