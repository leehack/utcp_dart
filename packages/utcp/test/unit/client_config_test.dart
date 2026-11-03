import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fake_protocol.dart';

void main() {
  setUpAll(() {
    CallTemplate.registry.register(
      FakeCallTemplate.type,
      FakeCallTemplate.fromJson,
    );
    VariableLoader.registry.register(
      _JsonLoader.type,
      (json) => _JsonLoader(json.string('label')),
    );
  });

  group('toJson', () {
    final fakeTemplate = {
      'name': 'm',
      'call_template_type': 'fake',
      'allowed_communication_protocols': ['fake', 'http'],
      'token': r'${TOKEN}',
    };
    final json = {
      'variables': {'m_TOKEN': r'${SECRET}', 'PLAIN': 'value'},
      'load_variables_from': [
        {'variable_loader_type': _JsonLoader.type, 'label': 'a'},
      ],
      'tool_repository': {'tool_repository_type': 'in_memory'},
      'tool_search_strategy': {
        'tool_search_strategy_type': 'tag_and_description_word_match',
        'description_weight': 2,
        'tag_weight': 5,
      },
      'manual_call_templates': [
        fakeTemplate,
        {
          'name': 'api',
          'call_template_type': 'http',
          'url': 'https://api.example.com/utcp',
          'http_method': 'GET',
          'auth': {
            'auth_type': 'api_key',
            'api_key': r'${API_KEY}',
            'var_name': 'X-Api-Key',
            'location': 'header',
          },
        },
      ],
      'post_processing': [
        {
          'tool_post_processor_type': 'limit_strings',
          'limit': 10,
          'only_include_manuals': ['m'],
        },
      ],
    };

    test('round-trips through fromJson', () {
      final config = UtcpClientConfig.fromJson(json);
      final written = jsonDecode(jsonEncode(config.toJson())) as JsonMap;
      expect(UtcpClientConfig.fromJson(written).toJson(), config.toJson());
      expect(written['variables'], json['variables']);
      expect(written['load_variables_from'], json['load_variables_from']);
      expect(written['tool_repository'], json['tool_repository']);
      expect(written['tool_search_strategy'], json['tool_search_strategy']);
      final templates = written['manual_call_templates']! as List<Object?>;
      expect(templates.first, fakeTemplate);
      expect(
        ((templates.last! as JsonMap)['auth']! as JsonMap)['api_key'],
        r'${API_KEY}',
      );
      expect(written['post_processing'], [
        containsPair('tool_post_processor_type', 'limit_strings'),
      ]);
    });

    test('leaves out loaders without a JSON form', () {
      final config = UtcpClientConfig(
        variableLoaders: [_JsonLoader('kept'), _PlainLoader()],
      );
      expect(config.toJson()['load_variables_from'], [
        {'variable_loader_type': _JsonLoader.type, 'label': 'kept'},
      ]);
    });

    test('an empty config round-trips', () {
      final json = UtcpClientConfig().toJson();
      expect(json, {
        'variables': <String, Object?>{},
        'load_variables_from': <Object?>[],
        'tool_repository': {'tool_repository_type': 'in_memory'},
        'tool_search_strategy': {
          'tool_search_strategy_type': 'tag_and_description_word_match',
          'description_weight': 1,
          'tag_weight': 3,
        },
        'manual_call_templates': <Object?>[],
        'post_processing': <Object?>[],
      });
      expect(UtcpClientConfig.fromJson(json).toJson(), json);
    });
  });

  test('tool_repository is parsed with its registry', () {
    ToolRepository.registry.register(
      'config_test_repository',
      (_) => _TypedRepository(),
    );
    final config = UtcpClientConfig.fromJson({
      'tool_repository': {'tool_repository_type': 'config_test_repository'},
    });
    expect(config.toolRepository, isA<_TypedRepository>());
    expect(config.toJson()['tool_repository'], {
      'tool_repository_type': 'config_test_repository',
    });
  });

  test(
    'fromFile is unsupported without dart:io',
    () => expectLater(
      UtcpClientConfig.fromFile('utcp_config.json'),
      throwsUnsupportedError,
    ),
    testOn: 'browser',
  );
}

class _JsonLoader extends VariableLoader {
  _JsonLoader(this.label);

  static const type = 'config_test_loader';

  final String label;

  @override
  String? get(String key) => null;

  @override
  JsonMap toJson() => {'variable_loader_type': type, 'label': label};
}

class _PlainLoader extends VariableLoader {
  @override
  String? get(String key) => null;
}

class _TypedRepository extends InMemoryToolRepository {
  @override
  JsonMap toJson() => {'tool_repository_type': 'config_test_repository'};
}
