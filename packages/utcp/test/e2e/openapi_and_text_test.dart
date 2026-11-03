@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/local_http_server.dart';
import '../support/openapi_fixtures.dart';

void main() {
  test('a client configured from JSON uses OpenAPI and text manuals', () async {
    final server = await LocalHttpServer.start((request, body) {
      if (request.uri.path == '/openapi.json') {
        request.response.json(petstoreOpenApi3(serverUrl: '/v1'));
        return;
      }
      if (request.headers.value('x-api-key') != 'pet-key') {
        request.response.json({'error': 'unauthorized'}, status: 401);
        return;
      }
      request.response.json({
        'id': request.uri.pathSegments.last,
        'name': 'Rex',
        'via': request.uri.path,
      });
    });
    addTearDown(server.close);

    final client = await UtcpClient.fromJson({
      'variables': {'petstore_PET_KEY': 'pet-key', 'inline_PET_KEY': 'pet-key'},
      'manual_call_templates': [
        {
          'name': 'petstore',
          'call_template_type': 'http',
          'url': '${server.baseUrl}/openapi.json',
          'auth_tools': {
            'auth_type': 'api_key',
            'api_key': r'${PET_KEY}',
            'var_name': 'X-Api-Key',
          },
        },
        {
          'name': 'notes',
          'call_template_type': 'text',
          'content': jsonEncode({
            'utcp_version': '1.0.1',
            'tools': [
              {
                'name': 'house_rules',
                'description': 'Rules for visiting the pet store',
                'tags': ['rules'],
                'tool_call_template': {
                  'call_template_type': 'text',
                  'content': 'No feeding the animals.',
                },
              },
            ],
          }),
        },
        {
          'name': 'inline',
          'call_template_type': 'text',
          'content': jsonEncode(petstoreOpenApi3()),
          'base_url': '${server.baseUrl}/inline',
          'allowed_communication_protocols': ['http'],
          'auth_tools': {
            'auth_type': 'api_key',
            'api_key': r'${PET_KEY}',
            'var_name': 'X-Api-Key',
          },
        },
      ],
    }, environment: const {});
    addTearDown(client.close);

    final found = await client.searchTools('specific pet');
    expect(found.map((t) => t.name), contains('petstore.showPetById'));
    expect(await client.callTool('petstore.showPetById', {'petId': '7'}), {
      'id': '7',
      'name': 'Rex',
      'via': '/v1/pets/7',
    });

    final rules = await client.searchTools('rules', limit: 1);
    expect(rules.single.name, 'notes.house_rules');
    expect(await client.callTool(rules.single.name), 'No feeding the animals.');

    expect(
      await client.callTool('inline.showPetById', {'petId': '8'}),
      containsPair('via', '/inline/pets/8'),
    );
  });
}
