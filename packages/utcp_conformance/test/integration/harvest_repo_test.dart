@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

Future<void> git(String dir, List<String> args) async {
  final result = await Process.run('git', [
    '-C',
    dir,
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@example.com',
    ...args,
  ]);
  if (result.exitCode != 0) fail('git $args: ${result.stderr}');
}

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('harvest_'));
  tearDown(() => temp.delete(recursive: true));

  test('harvests a commit from a clone without touching the tree', () async {
    final upstream = Directory('${temp.path}/upstream')..createSync();
    await git(upstream.path, ['init', '--quiet']);
    File('${upstream.path}/docs/protocols/http.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
# HTTP

```json
{"call_template_type": "http", "url": "https://a.example"}
```

```json
{"call_template_type": "http", "url": "https://a.example"}
```
''');
    File('${upstream.path}/versioned_docs/old.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('```json\n{"auth_type": "basic"}\n```\n');
    await git(upstream.path, ['add', '.']);
    await git(upstream.path, ['commit', '--quiet', '-m', 'docs']);

    final clone = Directory('${temp.path}/clone');
    await cloneRepo(UpstreamRef(upstream.path, 'HEAD'), clone);
    final commit = await resolveCommit(clone, 'HEAD');
    expect(commit, hasLength(40));

    final fixtures = await harvestRepo('utcp-specification', clone, commit);
    expect(fixtures, hasLength(1), reason: 'duplicates and old docs skipped');
    expect(
      fixtures.single.source.toString(),
      'utcp-specification/docs/protocols/http.md:4',
    );
    expect(fixtures.single.expect, Expectation.unreviewed);
    expect(
      clone.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
      ['.git'],
    );
  });

  test('reports git failures', () async {
    expect(() => resolveCommit(temp, 'HEAD'), throwsA(isA<HarvestException>()));
    expect(
      () => harvestRepo('unknown', temp, 'HEAD'),
      throwsA(isA<HarvestException>()),
    );
  });
}
