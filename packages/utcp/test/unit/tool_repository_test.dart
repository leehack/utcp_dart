import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fake_protocol.dart';

void main() {
  group('InMemoryToolRepository.removeTool', () {
    late InMemoryToolRepository repository;

    setUp(() async {
      repository = InMemoryToolRepository();
      await repository.saveManual(
        const FakeCallTemplate(name: 'm'),
        UtcpManual(tools: [fakeTool('m.a'), fakeTool('m.b')]),
      );
    });

    test('removes the tool from the repository and its manual', () async {
      expect(await repository.removeTool('m.a'), isTrue);
      expect(await repository.getTool('m.a'), isNull);
      expect((await repository.getTools()).map((t) => t.name), ['m.b']);
      expect((await repository.getToolsByManual('m'))!.map((t) => t.name), [
        'm.b',
      ]);
      expect((await repository.getManual('m'))!.tools.map((t) => t.name), [
        'm.b',
      ]);
    });

    test('returns false for an unknown tool', () async {
      expect(await repository.removeTool('m.missing'), isFalse);
      expect(await repository.getTools(), hasLength(2));
    });

    test('a removed tool stays removed when its manual is removed', () async {
      await repository.removeTool('m.a');
      expect(await repository.removeManual('m'), isTrue);
      expect(await repository.getTools(), isEmpty);
    });
  });

  group('ToolRepository.registry', () {
    test('parses in_memory, the default type', () {
      expect(
        ToolRepository.fromJson({'tool_repository_type': 'in_memory'}),
        isA<InMemoryToolRepository>(),
      );
      expect(ToolRepository.fromJson({}), isA<InMemoryToolRepository>());
    });

    test('rejects an unknown type', () {
      expect(
        () => ToolRepository.fromJson({'tool_repository_type': 'redis'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'redis'"),
          ),
        ),
      );
    });

    test('parses a type a plugin registers', () {
      ToolRepository.registry.register(
        _NamedRepository.type,
        (json) => _NamedRepository(json.string('label')),
      );
      final repository = ToolRepository.fromJson({
        'tool_repository_type': _NamedRepository.type,
        'label': 'x',
      });
      expect(repository, isA<_NamedRepository>());
      expect(repository.toJson(), {
        'tool_repository_type': _NamedRepository.type,
        'label': 'x',
      });
    });

    test('in_memory round-trips through toJson', () {
      final json = InMemoryToolRepository().toJson();
      expect(json, {'tool_repository_type': 'in_memory'});
      expect(ToolRepository.fromJson(json), isA<InMemoryToolRepository>());
    });
  });
}

class _NamedRepository extends InMemoryToolRepository {
  _NamedRepository(this.label);

  static const type = 'named_test_repository';

  final String label;

  @override
  JsonMap toJson() => {'tool_repository_type': type, 'label': label};
}
