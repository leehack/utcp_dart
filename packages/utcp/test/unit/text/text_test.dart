import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../support/openapi_fixtures.dart';

void main() {
  const manualJson = '''
{
  "utcp_version": "1.0.1",
  "tools": [
    {
      "name": "readme",
      "description": "Returns the project readme",
      "tags": ["docs"],
      "tool_call_template": {"call_template_type": "text", "content": "Hello"}
    }
  ]
}
''';
  const manualYaml = '''
tools:
  - name: readme
    tool_call_template:
      call_template_type: text
      content: Hello from YAML
''';

  late UtcpClient client;

  setUp(() async {
    client = await UtcpClient.create(
      config: UtcpClientConfig(environment: const {}),
    );
  });

  tearDown(() => client.close());

  group('TextCallTemplate', () {
    test('round-trips through JSON and is a built-in type', () {
      const template = TextCallTemplate(
        name: 'docs',
        content: 'x',
        baseUrl: 'https://api.example.com',
        authTools: ApiKeyAuth(apiKey: 'k'),
        allowedCommunicationProtocols: ['text', 'http'],
      );
      final parsed = CallTemplate.fromJson(template.toJson());
      expect(parsed, isA<TextCallTemplate>());
      expect(parsed.toJson(), template.toJson());
      expect(template.toJson(), {
        'name': 'docs',
        'call_template_type': 'text',
        'allowed_communication_protocols': ['text', 'http'],
        'content': 'x',
        'base_url': 'https://api.example.com',
        'auth_tools': const ApiKeyAuth(apiKey: 'k').toJson(),
      });
    });

    test('rejects file_path, auth and a missing content', () {
      expect(
        () => TextCallTemplate.fromJson({'file_path': 'm.json'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('file_path'),
          ),
        ),
      );
      expect(
        () => TextCallTemplate.fromJson({
          'content': 'x',
          'auth': const BasicAuth(username: 'u', password: 'p').toJson(),
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TextCallTemplate.fromJson({}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'content'"),
          ),
        ),
      );
    });
  });

  group('TextCommunicationProtocol', () {
    test('registers a JSON manual and returns content on call', () async {
      final result = await client.registerManual(
        const TextCallTemplate(name: 'docs', content: manualJson),
      );
      expect(result.success, isTrue, reason: '${result.errors}');
      final tools = await client.searchTools('readme');
      expect(tools.map((t) => t.name), ['docs.readme']);
      expect(await client.callTool('docs.readme'), 'Hello');
      expect(await client.callToolStreaming('docs.readme').toList(), ['Hello']);
    });

    test('registers a YAML manual', () async {
      await client.registerManual(
        const TextCallTemplate(name: 'docs', content: manualYaml),
      );
      expect(await client.callTool('docs.readme'), 'Hello from YAML');
    });

    test('converts an OpenAPI document in JSON or YAML', () async {
      final json = await client.registerManual(
        TextCallTemplate(
          name: 'petstore',
          content: jsonEncode(petstoreOpenApi3()),
          authTools: const ApiKeyAuth(apiKey: 'secret'),
          allowedCommunicationProtocols: const ['http'],
        ),
      );
      expect(
        json.manual.tools.map((t) => t.name),
        contains('petstore.createPet'),
      );
      final create = json.manual.tools.firstWhere(
        (t) => t.name == 'petstore.createPet',
      );
      expect(
        create.toolCallTemplate.toJson(),
        containsPair('auth', {...const ApiKeyAuth(apiKey: 'secret').toJson()}),
      );

      final yaml = await client.registerManual(
        TextCallTemplate(
          name: 'v2',
          content: petstoreSwaggerYaml(host: 'petstore.example.com'),
          allowedCommunicationProtocols: const ['http'],
        ),
      );
      expect(yaml.manual.tools.map((t) => t.name), [
        'v2.addPet',
        'v2.findPetsByStatus',
      ]);
    });

    test('converted http tools need http in allowed protocols', () async {
      final result = await client.registerManual(
        TextCallTemplate(name: 'p', content: jsonEncode(petstoreOpenApi3())),
      );
      expect(result.success, isTrue);
      expect(result.manual.tools, isEmpty);
    });

    test('treats inline OpenAPI as remote unless base_url is set', () async {
      final spec = jsonEncode(
        petstoreOpenApi3(serverUrl: 'http://localhost:8080'),
      );
      final refused = await client.registerManual(
        TextCallTemplate(name: 'local', content: spec),
      );
      expect(refused.success, isFalse);
      expect(refused.errors.single, contains('loopback'));

      final allowed = await client.registerManual(
        TextCallTemplate(
          name: 'local',
          content: spec,
          baseUrl: 'http://localhost:9090',
          allowedCommunicationProtocols: const ['http'],
        ),
      );
      expect(allowed.success, isTrue, reason: '${allowed.errors}');
      expect(
        allowed.manual.tools.first.toolCallTemplate.toJson()['url'],
        'http://localhost:9090/pets',
      );
    });

    test('reports unparsable or invalid content as a failure', () async {
      for (final (content, error) in [
        ('{"tools": [', 'Failed to parse content as JSON or YAML'),
        ('"just a string"', 'Text content must be a JSON object'),
        ('{"tools": "none"}', "Field 'tools' must be an array"),
      ]) {
        final result = await client.registerManual(
          TextCallTemplate(name: 'bad', content: content),
        );
        expect(result.success, isFalse);
        expect(
          result.errors.single,
          startsWith('Failed to register text manual: '),
        );
        expect(result.errors.single, contains(error));
      }
    });
  });
}
