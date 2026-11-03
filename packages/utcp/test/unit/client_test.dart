import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fake_protocol.dart';

void main() {
  Future<(UtcpClient, FakeProtocol)> clientWith(
    UtcpManual manual, {
    Map<String, String> variables = const {},
    List<String> errors = const [],
  }) async {
    final protocol = FakeProtocol(manual: manual, errors: errors);
    final client = await UtcpClient.create(
      config: UtcpClientConfig(variables: variables, environment: const {}),
      protocols: [protocol],
    );
    return (client, protocol);
  }

  test('registration sanitizes the manual name and prefixes tools', () async {
    final (client, _) = await clientWith(
      UtcpManual(tools: [fakeTool('echo'), fakeTool('my-api.already')]),
    );
    final result = await client.registerManual(
      const FakeCallTemplate(name: 'my-api'),
    );
    expect(result.success, isTrue);
    expect(result.manualCallTemplate.name, 'my_api');
    expect((await client.getTools()).map((t) => t.name), [
      'my_api.echo',
      'my_api.my-api.already',
    ]);
  });

  test(
    'Unicode letters and numbers survive sanitizing, as in Python',
    () async {
      final (client, _) = await clientWith(
        UtcpManual(tools: [fakeTool('echo', token: r'${TOKEN}')]),
        variables: {'café__٣_TOKEN': 't'},
      );
      const template = FakeCallTemplate(name: 'café-٣', token: r'${TOKEN}');
      expect(client.getRequiredVariablesForManual(template), ['café__٣_TOKEN']);
      final result = await client.registerManual(template);
      expect(result.manualCallTemplate.name, 'café_٣');
      expect((await client.getTools()).single.name, 'café_٣.echo');
      expect(await client.callTool('café_٣.echo'), containsPair('token', 't'));
    },
  );

  test('a manual without a name gets a random one', () async {
    final (client, _) = await clientWith(UtcpManual(tools: [fakeTool('echo')]));
    final result = await client.registerManual(const FakeCallTemplate());
    expect(
      result.manualCallTemplate.name,
      matches(RegExp(r'^manual_[0-9a-f]{16}$')),
    );
  });

  test('registering the same manual name twice throws', () async {
    final (client, _) = await clientWith(const UtcpManual(tools: []));
    await client.registerManual(const FakeCallTemplate(name: 'm'));
    expect(
      client.registerManual(const FakeCallTemplate(name: 'm')),
      throwsA(isA<UtcpException>()),
    );
  });

  test('a failed discovery is returned and nothing is stored', () async {
    final (client, _) = await clientWith(
      const UtcpManual(tools: []),
      errors: ['down'],
    );
    final result = await client.registerManual(
      const FakeCallTemplate(name: 'm'),
    );
    expect(result.success, isFalse);
    expect(result.errors, ['down']);
    expect(await client.config.toolRepository.getManual('m'), isNull);
  });

  test(
    'tools using a protocol the manual does not allow are dropped',
    () async {
      final (client, _) = await clientWith(
        UtcpManual(
          tools: [
            fakeTool('ok'),
            const Tool(
              name: 'web',
              toolCallTemplate: HttpCallTemplate(url: 'https://a'),
            ),
          ],
        ),
      );
      await client.registerManual(const FakeCallTemplate(name: 'm'));
      expect((await client.getTools()).map((t) => t.name), ['m.ok']);
    },
  );

  test(
    'a call substitutes namespaced variables and routes to the protocol',
    () async {
      final (client, protocol) = await clientWith(
        UtcpManual(tools: [fakeTool('echo', token: r'${TOKEN}')]),
        variables: {'m_TOKEN': 'secret'},
      );
      await client.registerManual(const FakeCallTemplate(name: 'm'));
      expect(await client.callTool('m.echo', {'x': 1}), {
        'tool': 'm.echo',
        'token': 'secret',
        'x': 1,
      });
      expect(protocol.calls.single.$3.token, 'secret');
      expect(await client.callToolStreaming('m.echo').toList(), [
        {'tool': 'm.echo', 'token': 'secret'},
      ]);
      expect(await client.getRequiredVariablesForRegisteredTool('m.echo'), [
        'm_TOKEN',
      ]);
    },
  );

  test('config variables may reference loaders and the environment', () async {
    final client = await UtcpClient.create(
      config: UtcpClientConfig(
        variables: {'m_TOKEN': r'Bearer ${RAW}'},
        environment: const {'RAW': 'env-token'},
      ),
      protocols: [
        FakeProtocol(
          manual: UtcpManual(tools: [fakeTool('echo', token: r'$TOKEN')]),
        ),
      ],
    );
    await client.registerManual(const FakeCallTemplate(name: 'm'));
    expect(
      await client.callTool('m.echo'),
      containsPair('token', 'Bearer env-token'),
    );
  });

  test('calling an unknown tool or a disallowed protocol throws', () async {
    final (client, _) = await clientWith(UtcpManual(tools: [fakeTool('echo')]));
    await client.registerManual(const FakeCallTemplate(name: 'm'));
    expect(client.callTool('m.nope'), throwsA(isA<UtcpException>()));

    // A repository holding a tool the manual does not allow, for example
    // one shared with another client, is still refused at call time.
    await client.config.toolRepository.saveManual(
      const FakeCallTemplate(name: 'shared'),
      const UtcpManual(
        tools: [
          Tool(
            name: 'shared.web',
            toolCallTemplate: HttpCallTemplate(url: 'https://a.example'),
          ),
        ],
      ),
    );
    await expectLater(
      client.callTool('shared.web'),
      throwsA(isA<UtcpSecurityException>()),
    );
  });

  test('deregistering removes tools and notifies the protocol', () async {
    final (client, protocol) = await clientWith(
      UtcpManual(tools: [fakeTool('echo')]),
    );
    await client.registerManual(const FakeCallTemplate(name: 'm'));
    expect(await client.deregisterManual('m'), isTrue);
    expect(await client.getTools(), isEmpty);
    expect(protocol.deregistered, 1);
    expect(await client.deregisterManual('m'), isFalse);
  });

  test('registerManuals reports failures without throwing', () async {
    final (client, _) = await clientWith(const UtcpManual(tools: []));
    final results = await client.registerManuals([
      const FakeCallTemplate(name: 'a'),
      const FakeCallTemplate(name: 'a'),
    ]);
    expect(results.where((r) => r.success), hasLength(1));
    expect(
      results.where((r) => !r.success).single.errors.single,
      contains('already registered'),
    );
  });

  test('close closes every protocol', () async {
    final (client, protocol) = await clientWith(const UtcpManual(tools: []));
    await client.close();
    expect(protocol.closed, isTrue);
  });

  test('fromJson registers protocol types before parsing the config', () async {
    final protocol = FakeProtocol(
      manual: UtcpManual(tools: [fakeTool('echo')]),
    );
    final client = await UtcpClient.fromJson(
      {
        'variables': {'m_TOKEN': 't'},
        'manual_call_templates': [
          {'name': 'm', 'call_template_type': 'fake'},
        ],
        'tool_search_strategy': {
          'tool_search_strategy_type': 'tag_and_description_word_match',
          'tag_weight': 5,
        },
      },
      protocols: [protocol],
      environment: const {},
    );
    expect((await client.getTools()).single.name, 'm.echo');
    expect(
      (client.config.toolSearchStrategy as TagSearchStrategy).tagWeight,
      5,
    );
  });

  test('rootDir is kept for transports', () async {
    final created = await UtcpClient.create(rootDir: '/srv/utcp');
    final parsed = await UtcpClient.fromJson(const {}, rootDir: '/srv/utcp');
    final defaulted = await UtcpClient.create();
    addTearDown(
      () => Future.wait([created.close(), parsed.close(), defaulted.close()]),
    );
    expect(created.rootDir, '/srv/utcp');
    expect(parsed.rootDir, '/srv/utcp');
    expect(defaulted.rootDir, isNull);
  });

  group('call template parsing is scoped to the client', () {
    test(
      'a protocol replacing a core type does not change other parsing',
      () async {
        final protocol = _OverridingProtocol(HttpCallTemplate.type);
        final client = await UtcpClient.create(
          config: UtcpClientConfig(environment: const {}),
          protocols: [protocol],
        );
        addTearDown(client.close);
        final http = {
          'name': 'api',
          'call_template_type': 'http',
          'url': 'https://api.example.com/utcp',
        };
        expect(CallTemplate.fromJson(http), isA<HttpCallTemplate>());
        expect(
          await client.substituteCallTemplateVariables(
            HttpCallTemplate.fromJson(http),
          ),
          isA<_TaggedTemplate>(),
        );
        // Tools parsed by the transport during discovery use it too.
        final result = await client.registerManual(
          const _TaggedTemplate('http', 'm'),
        );
        expect(result.success, isTrue);
        expect(
          (await client.getTools()).single.toolCallTemplate,
          isA<_TaggedTemplate>(),
        );
        expect(CallTemplate.fromJson(http), isA<HttpCallTemplate>());
      },
    );

    test('fromJson parses the config with the client protocols', () async {
      final client = await UtcpClient.fromJson(
        const {
          'manual_call_templates': [
            {
              'name': 'm',
              'call_template_type': 'http',
              'url': 'https://api.example.com/utcp',
            },
          ],
        },
        protocols: [_OverridingProtocol(HttpCallTemplate.type)],
        environment: const {},
      );
      addTearDown(client.close);
      expect(client.config.manualCallTemplates.single, isA<_TaggedTemplate>());
      expect((await client.getTools()).single.name, 'm.tool');
    });

    test('a type not yet known is still registered globally', () async {
      const type = 'scoped_test_new_type';
      expect(CallTemplate.registry.contains(type), isFalse);
      final client = await UtcpClient.create(
        protocols: [_OverridingProtocol(type)],
      );
      addTearDown(client.close);
      expect(
        CallTemplate.fromJson({'call_template_type': type}),
        isA<_TaggedTemplate>(),
      );
    });
  });

  test('unsupported config sections are rejected', () {
    expect(
      () => UtcpClientConfig.fromJson({
        'tool_repository': {'tool_repository_type': 'redis'},
      }),
      throwsFormatException,
    );
    expect(
      () => UtcpClientConfig.fromJson({
        'tool_search_strategy': {'tool_search_strategy_type': 'embeddings'},
      }),
      throwsFormatException,
    );
  });

  group('post_processing', () {
    final config = {
      'manual_call_templates': [
        {'name': 'm', 'call_template_type': 'fake'},
      ],
      'post_processing': [
        {
          'tool_post_processor_type': 'filter_dict',
          'exclude_keys': ['secret'],
        },
        {'tool_post_processor_type': 'limit_strings', 'limit': 2},
      ],
    };

    test('is parsed from the config in order', () {
      final parsed = UtcpClientConfig.fromJson({
        'post_processing': config['post_processing'],
      });
      expect(parsed.postProcessing.map((p) => p.toolPostProcessorType), [
        'filter_dict',
        'limit_strings',
      ]);
      expect(
        () => UtcpClientConfig.fromJson({
          'post_processing': [
            {'tool_post_processor_type': 'nope'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('runs in order on callTool results', () async {
      final client = await UtcpClient.fromJson(
        config,
        protocols: [
          FakeProtocol(manual: UtcpManual(tools: [fakeTool('echo')])),
        ],
        environment: const {},
      );
      addTearDown(client.close);
      expect(await client.callTool('m.echo', {'secret': 'x', 'word': 'abc'}), {
        'tool': 'm.',
        'token': null,
        'word': 'ab',
      });
    });

    test('runs on every streamed chunk', () async {
      final client = await UtcpClient.fromJson(
        config,
        protocols: [
          FakeProtocol(
            manual: UtcpManual(tools: [fakeTool('echo')]),
            chunks: [
              {'secret': 1, 'a': 'xyz'},
              'long',
              [
                {'secret': 2},
              ],
            ],
          ),
        ],
        environment: const {},
      );
      addTearDown(client.close);
      expect(await client.callToolStreaming('m.echo').toList(), [
        {'a': 'xy'},
        'lo',
        <Object?>[],
      ]);
    });

    test('receives the tool and its manual call template', () async {
      final seen = <(String, String?)>[];
      final client = await UtcpClient.create(
        config: UtcpClientConfig(
          environment: const {},
          manualCallTemplates: [const FakeCallTemplate(name: 'm')],
          postProcessing: [_Recorder(seen)],
        ),
        protocols: [
          FakeProtocol(manual: UtcpManual(tools: [fakeTool('echo')])),
        ],
      );
      addTearDown(client.close);
      await client.callTool('m.echo');
      expect(seen, [('m.echo', 'm')]);
    });
  });
}

class _Recorder extends ToolPostProcessor {
  _Recorder(this.seen);

  final List<(String, String?)> seen;

  @override
  String get toolPostProcessorType => 'recorder';

  @override
  Object? postProcess(
    UtcpClient caller,
    Tool tool,
    CallTemplate manualCallTemplate,
    Object? result,
  ) {
    seen.add((tool.name, manualCallTemplate.name));
    return result;
  }

  @override
  JsonMap fieldsToJson() => const {};
}

/// Serves [type] with its own template class, and discovers one tool whose
/// template has that type.
class _OverridingProtocol extends CommunicationProtocol {
  _OverridingProtocol(this.type);

  final String type;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => {
    type: (json) => _TaggedTemplate(type, json.optString('name')),
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async => RegisterManualResult(
    manualCallTemplate: manualCallTemplate,
    manual: UtcpManual.fromJson({
      'tools': [
        {
          'name': 'tool',
          'tool_call_template': {
            'call_template_type': type,
            'url': 'https://api.example.com/tool',
          },
        },
      ],
    }),
  );

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async => null;
}

class _TaggedTemplate extends CallTemplate {
  const _TaggedTemplate(this.callTemplateType, [String? name])
    : super(name: name);

  @override
  final String callTemplateType;

  @override
  JsonMap fieldsToJson() => const {};
}
