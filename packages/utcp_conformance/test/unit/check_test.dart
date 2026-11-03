import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

Fixture fixture(
  Expectation expect, {
  JsonMap document = const {},
  List<String> mayDrop = const [],
  String? rejectError,
}) => Fixture(
  id: 'id',
  source: const FixtureSource('repo', 'a.md', 1),
  kind: DocumentKind.callTemplate,
  expect: expect,
  reason: 'why',
  mayDrop: mayDrop,
  rejectError: rejectError,
  document: document,
);

const http = {
  'name': 'weather',
  'call_template_type': 'http',
  'url': 'https://api.example.com/utcp',
  'http_method': 'GET',
};

void main() {
  late List<CommunicationProtocol> protocols;
  setUpAll(() => protocols = registerAllProtocols());
  tearDownAll(() async {
    for (final protocol in protocols) {
      await protocol.close();
    }
  });

  group('lostPaths', () {
    test('reports missing and changed values at the shallowest path', () {
      expect(
        lostPaths(
          {
            'a': 1,
            'b': {'c': 2, 'd': 3},
            'e': [
              {'f': 1},
            ],
            'g': {'h': 1},
          },
          {
            'a': 1,
            'b': {'c': 2},
            'e': [
              {'f': 2},
            ],
            'added': true,
          },
        ),
        unorderedEquals(['b.d', 'e.*.f', 'g']),
      );
    });

    test('treats an explicit null as absent and 1 as 1.0', () {
      expect(
        lostPaths({'a': null, 'b': 1}, {'a': <Object?>[], 'b': 1.0}),
        isEmpty,
      );
    });

    test('reports a type change or a shorter array', () {
      expect(lostPaths({'a': '1'}, {'a': 1}), ['a']);
      expect(
        lostPaths(
          {
            'a': [1, 2],
          },
          {
            'a': [1],
          },
        ),
        ['a'],
      );
      expect(lostPaths({'a': <String, Object?>{}}, {'a': 'x'}), ['a']);
    });
  });

  test('covers matches segments, wildcards and descendants', () {
    expect(covers('info', 'info'), isTrue);
    expect(covers('info', 'info.title'), isTrue);
    expect(covers('tools.*.auth', 'tools.*.auth'), isTrue);
    expect(covers('*.auth', 'tools.auth'), isTrue);
    expect(covers('info.title', 'info'), isFalse);
    expect(covers('info', 'information'), isFalse);
  });

  group('Outcome', () {
    test('round-trips an accepted document', () {
      final outcome = Outcome.of(DocumentKind.callTemplate, {
        ...http,
        'timeout': 30,
      });
      expect(outcome.accepted, isTrue);
      expect(outcome.unstable, isFalse);
      expect(outcome.lost, ['timeout']);
      expect(outcome.summary, 'accepts, drops timeout');
    });

    test('records a rejection', () {
      final outcome = Outcome.of(DocumentKind.callTemplate, {
        'call_template_type': 'nope',
      });
      expect(outcome.accepted, isFalse);
      expect(outcome.crash, isNull);
      expect(outcome.summary, startsWith('rejects: Unknown'));
    });

    test('parses every kind', () {
      final documents = <DocumentKind, JsonMap>{
        DocumentKind.clientConfig: {
          'manual_call_templates': [http],
        },
        DocumentKind.manual: {
          'utcp_version': utcpProtocolVersion,
          'manual_version': '1.0.0',
          'tools': <Object?>[],
        },
        DocumentKind.tool: {'name': 't', 'tool_call_template': http},
        DocumentKind.callTemplate: http,
        DocumentKind.auth: {
          'auth_type': 'basic',
          'username': 'u',
          'password': 'p',
        },
        DocumentKind.variableLoader: {
          'variable_loader_type': 'dotenv',
          'env_file_path': '.env',
        },
        DocumentKind.postProcessor: {
          'tool_post_processor_type': 'limit_strings',
          'limit': 5,
        },
        DocumentKind.toolRepository: {'tool_repository_type': 'in_memory'},
        DocumentKind.toolSearchStrategy: {
          'tool_search_strategy_type': 'tag_and_description_word_match',
        },
      };
      expect(documents.keys, unorderedEquals(DocumentKind.values));
      for (final MapEntry(key: kind, value: document) in documents.entries) {
        final outcome = Outcome.of(kind, document);
        expect(outcome.summary, 'accepts', reason: kind.wire);
      }
    });

    test('parses every transport package call template type', () {
      for (final type in [
        'mcp',
        'cli',
        'file',
        'tcp',
        'udp',
        'websocket',
        'sse',
        'streamable_http',
        'text',
      ]) {
        expect(CallTemplate.registry.contains(type), isTrue, reason: type);
      }
    });
  });

  group('problems', () {
    test('accepts what matches the fixture', () {
      expect(
        problems(
          fixture(Expectation.accept, document: http),
          Outcome.of(DocumentKind.callTemplate, http),
        ),
        isEmpty,
      );
      final bad = {'call_template_type': 'nope'};
      expect(
        problems(
          fixture(Expectation.reject, document: bad),
          Outcome.of(DocumentKind.callTemplate, bad),
        ),
        isEmpty,
      );
    });

    test('flags a wrong verdict, an unexpected drop and a stale may_drop', () {
      final extra = {...http, 'timeout': 1};
      expect(
        problems(
          fixture(Expectation.reject, document: http),
          Outcome.of(DocumentKind.callTemplate, http),
        ),
        [contains('expected a rejection')],
      );
      final bad = {'call_template_type': 'nope'};
      expect(
        problems(
          fixture(Expectation.reject, document: bad, rejectError: 'missing'),
          Outcome.of(DocumentKind.callTemplate, bad),
        ),
        [contains('expected a rejection containing "missing"')],
      );
      expect(
        problems(
          fixture(Expectation.reject, document: bad, rejectError: 'nope'),
          Outcome.of(DocumentKind.callTemplate, bad),
        ),
        isEmpty,
      );
      expect(
        problems(
          fixture(Expectation.accept, document: extra),
          Outcome.of(DocumentKind.callTemplate, extra),
        ),
        [contains('drops timeout')],
      );
      expect(
        problems(
          fixture(Expectation.accept, document: http, mayDrop: ['url']),
          Outcome.of(DocumentKind.callTemplate, http),
        ),
        [contains('may_drop lists url')],
      );
      expect(
        problems(
          fixture(Expectation.accept, document: extra, mayDrop: ['timeout']),
          Outcome.of(DocumentKind.callTemplate, extra),
        ),
        isEmpty,
      );
    });

    test('fails unreviewed fixtures', () {
      expect(
        problems(
          fixture(Expectation.unreviewed, document: http),
          Outcome.of(DocumentKind.callTemplate, http),
        ),
        [contains('not reviewed')],
      );
    });
  });

  group('fixtureId', () {
    test('ignores key order and follows content and path', () {
      final a = fixtureId('docs/a.md', {'x': 1, 'y': 2});
      expect(a, fixtureId('docs/a.md', {'y': 2, 'x': 1}));
      expect(a, startsWith('docs.a.md-'));
      expect(a, isNot(fixtureId('docs/a.md', {'x': 2, 'y': 2})));
      expect(a, isNot(fixtureId('docs/b.md', {'x': 1, 'y': 2})));
    });
  });

  test('a fixture round-trips through its JSON form', () {
    const original = Fixture(
      id: 'id',
      source: FixtureSource('repo', 'a.md', 3),
      kind: DocumentKind.auth,
      expect: Expectation.accept,
      reason: 'why',
      mayDrop: ['x'],
      knownFailure: 'bug',
      rejectError: 'no',
      document: {'auth_type': 'basic'},
    );
    final copy = Fixture.fromJson('id', original.toJson());
    expect(copy.toJson(), original.toJson());
    expect(
      () => Fixture.fromJson('id', {...original.toJson(), 'expect': 'maybe'}),
      throwsFormatException,
    );
  });
}
