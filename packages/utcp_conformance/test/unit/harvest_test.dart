import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

Fixture harvested(String path, int line, JsonMap document) => Fixture(
  id: fixtureId(path, document),
  source: FixtureSource('utcp-specification', path, line),
  kind: classify(document)!,
  expect: Expectation.unreviewed,
  document: document,
);

const lock = RefsLock('1.1', {
  'utcp-specification': UpstreamRef(
    'https://github.com/o/utcp-specification.git',
    '1111111111111111111111111111111111111111',
  ),
});

void main() {
  final kept = harvested('docs/a.md', 3, {'auth_type': 'basic'});
  final gone = harvested('docs/a.md', 9, {'auth_type': 'oauth2'});
  final reviewed = Corpus([
    for (final f in [kept, gone])
      Fixture(
        id: f.id,
        source: f.source,
        kind: f.kind,
        expect: Expectation.reject,
        reason: 'needs credentials',
        document: f.document,
      ),
  ]);

  test('an identical harvest is no drift', () {
    final diff = CorpusDiff(reviewed, [kept, gone]);
    expect(diff.isEmpty, isTrue);
    expect(diff.changesContent, isFalse);
  });

  test('documents that only moved lines do not change content', () {
    final moved = harvested('docs/a.md', 4, {'auth_type': 'basic'});
    final diff = CorpusDiff(reviewed, [moved, gone]);
    expect(diff.isEmpty, isFalse);
    expect(diff.changesContent, isFalse);
    final added = harvested('docs/b.md', 1, {'auth_type': 'api_key'});
    expect(CorpusDiff(reviewed, [moved, gone, added]).changesContent, isTrue);
    expect(CorpusDiff(reviewed, [kept]).changesContent, isTrue);
  });

  test('reports new, gone and moved documents', () {
    final moved = harvested('docs/a.md', 4, {'auth_type': 'basic'});
    final added = harvested('docs/b.md', 1, {'call_template_type': 'nope'});
    final diff = CorpusDiff(reviewed, [moved, added]);
    expect(diff.added.map((f) => f.id), [added.id]);
    expect(diff.removed.map((f) => f.id), [gone.id]);
    expect(diff.moved.single.$2.source.line, 4);

    final report = diff.report(lock, {
      'utcp-specification': '2222222222222222222222222222222222222222',
    });
    expect(report, contains('| utcp-specification | [`1111111`]'));
    expect(report, contains('[`2222222`]'));
    expect(report, contains('### New or changed documents (1)'));
    expect(
      report,
      contains(
        'https://github.com/o/utcp-specification/blob/'
        '2222222222222222222222222222222222222222/docs/b.md#L1',
      ),
    );
    expect(report, contains("Dart rejects: Unknown call_template_type 'nope'"));
    expect(report, contains('### Documents gone or changed upstream (1)'));
    expect(report, contains('was reject (needs credentials)'));
    expect(report, contains('### Documents that moved (1)'));
    expect(report, contains('was line 3'));
  });

  test('updatedTo keeps reviews and adds new documents unreviewed', () {
    final moved = harvested('docs/a.md', 4, {'auth_type': 'basic'});
    final added = harvested('docs/b.md', 1, {'auth_type': 'api_key'});
    final updated = reviewed.updatedTo([moved, added]);
    final byId = {for (final f in updated.fixtures.values) f.id: f};
    expect(byId.keys, unorderedEquals([kept.id, added.id]));
    expect(byId[kept.id]!.expect, Expectation.reject);
    expect(byId[kept.id]!.source.line, 4);
    expect(byId[added.id]!.expect, Expectation.unreviewed);
  });

  group('files', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('corpus_'));
    tearDown(() => temp.delete(recursive: true));

    test('a corpus and a lock survive a write and read', () {
      final dir = Directory('${temp.path}/fixtures');
      File('${dir.path}/utcp-specification/stale.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      reviewed.write(dir);
      final read = Corpus.read(dir);
      expect(read.fixtures.keys, unorderedEquals(reviewed.fixtures.keys));
      expect(
        read.fixtures.values.map((f) => f.toJson()),
        unorderedEquals(reviewed.fixtures.values.map((f) => f.toJson())),
      );

      final file = File('${temp.path}/refs.lock');
      lock.withCommits({'utcp-specification': 'abc'}).write(file);
      final again = RefsLock.read(file);
      expect(again.specVersion, '1.1');
      expect(again.repos['utcp-specification']!.commit, 'abc');
    });

    test('a malformed fixture names its file', () {
      final dir = Directory('${temp.path}/fixtures');
      File('${dir.path}/repo/bad.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"kind": "manual"}');
      expect(
        () => Corpus.read(dir),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('bad.json'),
          ),
        ),
      );
    });
  });
}
