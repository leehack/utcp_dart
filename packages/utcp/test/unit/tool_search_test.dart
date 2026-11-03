import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fake_protocol.dart';

void main() {
  late InMemoryToolRepository repository;

  setUp(() async {
    repository = InMemoryToolRepository();
    await repository.saveManual(
      const FakeCallTemplate(name: 'm'),
      UtcpManual(
        tools: [
          fakeTool(
            'm.get_weather',
            tags: ['weather', 'forecast'],
            description: 'Current weather for a city',
          ),
          fakeTool(
            'm.create_note',
            tags: ['notes'],
            description: 'Create a note',
          ),
          fakeTool(
            'm.list_authors',
            tags: ['books'],
            description: 'List authors of books',
          ),
        ],
      ),
    );
  });

  test('ranks name, tag and description matches', () async {
    final results = await const TagSearchStrategy().searchTools(
      repository,
      'weather forecast',
    );
    expect(results.first.name, 'm.get_weather');
  });

  test('partial words match descriptions and tags', () async {
    final results = await const TagSearchStrategy().searchTools(
      repository,
      'author',
    );
    expect(results.first.name, 'm.list_authors');
  });

  test('filters by required tags and honors the limit', () async {
    final strategy = const TagSearchStrategy();
    expect(
      (await strategy.searchTools(
        repository,
        'x',
        anyOfTagsRequired: ['NOTES'],
      )).map((t) => t.name),
      ['m.create_note'],
    );
    expect(await strategy.searchTools(repository, 'x', limit: 2), hasLength(2));
  });

  test('a limit of 0 or less returns every tool, as in TypeScript', () async {
    // Python returns [] for 0 and raises for a negative limit.
    final strategy = const TagSearchStrategy();
    expect(await strategy.searchTools(repository, 'x', limit: 0), hasLength(3));
    expect(
      await strategy.searchTools(repository, 'x', limit: -1),
      hasLength(3),
    );
  });

  test('the tool name is scored, as in TypeScript', () async {
    // Python scores only tags and description words, so it would rank
    // m.summarize (a description match) above m.translate.
    await repository.saveManual(
      const FakeCallTemplate(name: 'n'),
      UtcpManual(
        tools: [
          fakeTool('n.summarize', description: 'Summarize, then translate'),
          fakeTool('n.translate', description: 'Turns text into French'),
        ],
      ),
    );
    final results = await const TagSearchStrategy().searchTools(
      repository,
      'translate',
    );
    expect(results.take(2).map((t) => t.name), ['n.translate', 'n.summarize']);
  });

  test('ties keep registration order', () async {
    final results = await const TagSearchStrategy().searchTools(
      repository,
      'zzz',
    );
    expect(results.map((t) => t.name), [
      'm.get_weather',
      'm.create_note',
      'm.list_authors',
    ]);
  });

  test(
    'the repository replaces a manual saved twice and removes its tools',
    () async {
      await repository.saveManual(
        const FakeCallTemplate(name: 'm'),
        UtcpManual(tools: [fakeTool('m.only')]),
      );
      expect((await repository.getTools()).map((t) => t.name), ['m.only']);
      expect(await repository.removeManual('m'), isTrue);
      expect(await repository.getTools(), isEmpty);
      expect(await repository.getManualCallTemplates(), isEmpty);
    },
  );

  group('ToolSearchStrategy.registry', () {
    test('tag_and_description_word_match is the default type', () {
      final strategy = ToolSearchStrategy.fromJson({'tag_weight': 5});
      expect(strategy, isA<TagSearchStrategy>());
      expect(strategy.toJson(), {
        'tool_search_strategy_type': 'tag_and_description_word_match',
        'description_weight': 1,
        'tag_weight': 5,
      });
    });

    test('the tag strategy round-trips through toJson', () {
      const strategy = TagSearchStrategy(descriptionWeight: 2, tagWeight: 4);
      final again = ToolSearchStrategy.fromJson(strategy.toJson());
      expect(again.toJson(), strategy.toJson());
    });

    test('rejects an unknown type', () {
      expect(
        () => ToolSearchStrategy.fromJson({
          'tool_search_strategy_type': 'embeddings',
        }),
        throwsFormatException,
      );
    });

    test('parses a type a plugin registers', () async {
      ToolSearchStrategy.registry.register(
        _NameOrderStrategy.type,
        (_) => const _NameOrderStrategy(),
      );
      final strategy = ToolSearchStrategy.fromJson({
        'tool_search_strategy_type': _NameOrderStrategy.type,
      });
      expect(
        (await strategy.searchTools(repository, 'anything')).map((t) => t.name),
        ['m.create_note', 'm.get_weather', 'm.list_authors'],
      );
    });
  });
}

class _NameOrderStrategy implements ToolSearchStrategy {
  const _NameOrderStrategy();

  static const type = 'name_order_test';

  @override
  Future<List<Tool>> searchTools(
    ToolRepository repository,
    String query, {
    int limit = 10,
    List<String>? anyOfTagsRequired,
  }) async =>
      (await repository.getTools()).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  JsonMap toJson() => {'tool_search_strategy_type': type};
}
