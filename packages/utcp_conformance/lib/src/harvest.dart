import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';

import 'check.dart';
import 'extract.dart';
import 'fixture.dart';

/// An upstream repository the corpus is harvested from.
class UpstreamRef {
  /// Creates a reference to [commit] of the repository at [url].
  const UpstreamRef(this.url, this.commit);

  /// Reads one `repos` entry of `refs.lock`.
  factory UpstreamRef.fromJson(JsonMap json) =>
      UpstreamRef(json.string('url'), json.string('commit'));

  /// The clone URL.
  final String url;

  /// The full commit SHA.
  final String commit;

  /// The JSON form read by [UpstreamRef.fromJson].
  JsonMap toJson() => {'url': url, 'commit': commit};
}

/// The contents of `refs.lock`: the spec version Dart targets and the
/// upstream commits the corpus was last harvested and verified at.
class RefsLock {
  /// Creates a lock of [repos] by name.
  const RefsLock(this.specVersion, this.repos);

  /// Reads `refs.lock`.
  factory RefsLock.read(File file) {
    final json = asJsonMap(jsonDecode(file.readAsStringSync()), file.path);
    final repos = json.object('repos');
    return RefsLock(json.string('spec_version'), {
      for (final name in repos.keys)
        name: UpstreamRef.fromJson(repos.object(name)),
    });
  }

  /// The UTCP specification version (`major.minor`) Dart targets.
  final String specVersion;

  /// The upstream repositories by name.
  final Map<String, UpstreamRef> repos;

  /// This lock with [commits] (repository name to SHA) applied.
  RefsLock withCommits(Map<String, String> commits) => RefsLock(specVersion, {
    for (final MapEntry(key: name, value: ref) in repos.entries)
      name: UpstreamRef(ref.url, commits[name] ?? ref.commit),
  });

  /// Writes the lock to [file].
  void write(File file) {
    final json = {
      'spec_version': specVersion,
      'repos': {
        for (final MapEntry(key: name, value: ref) in repos.entries)
          name: ref.toJson(),
      },
    };
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );
  }
}

/// The files of each repository that hold UTCP documents: the spec's
/// current docs and its static manuals, and each SDK's Markdown and tests.
/// Old spec versions (`versioned_docs/`) and the provider registry
/// (`static/providers.json`, website data in the v0.1 format) are left out.
const harvestPaths = <String, List<String>>{
  'utcp-specification': [
    r'^README\.md$',
    r'^docs/.*\.mdx?$',
    r'^static/manuals/.*\.json$',
  ],
  'python-utcp': [r'(^|/)[^/]+\.md$', r'(^|/)tests/.+\.(py|json)$'],
  'typescript-utcp': [r'(^|/)[^/]+\.md$', r'(^|/)tests/.+\.(ts|json)$'],
};

/// Raised when a git command or the harvest setup fails.
class HarvestException implements Exception {
  /// Creates an exception with [message].
  HarvestException(this.message);

  /// What failed.
  final String message;

  @override
  String toString() => message;
}

Future<String> _git(List<String> args, {String? dir}) async {
  final result = await Process.run('git', [
    if (dir != null) ...['-C', dir],
    ...args,
  ], stdoutEncoding: utf8);
  if (result.exitCode != 0) {
    throw HarvestException('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}';
}

/// Clones [ref] into [dir] without a working tree.
Future<void> cloneRepo(UpstreamRef ref, Directory dir) =>
    _git(['clone', '--quiet', '--no-checkout', ref.url, dir.path]);

/// The commit [rev] names in the repository at [dir].
Future<String> resolveCommit(Directory dir, String rev) async => (await _git([
  'rev-parse',
  '--verify',
  '$rev^{commit}',
], dir: dir.path)).trim();

/// Every UTCP document in [commit] of the repository [name] at [dir], as
/// unreviewed fixtures. Reads blobs from git, so the working tree is never
/// touched. A document repeated in one file is kept once.
Future<List<Fixture>> harvestRepo(
  String name,
  Directory dir,
  String commit,
) async {
  final patterns = [
    for (final pattern
        in harvestPaths[name] ??
            (throw HarvestException('No harvest paths for $name.')))
      RegExp(pattern),
  ];
  final paths =
      (await _git(['ls-tree', '-r', '--name-only', commit], dir: dir.path))
          .split('\n')
          .where((path) => patterns.any((p) => p.hasMatch(path)))
          .toList()
        ..sort();
  final fixtures = <Fixture>[];
  for (final path in paths) {
    final contents = await _git(['show', '$commit:$path'], dir: dir.path);
    final seen = <String>{};
    for (final found in extractDocuments(path, contents)) {
      final id = fixtureId(path, found.document);
      if (!seen.add(id)) continue;
      fixtures.add(
        Fixture(
          id: id,
          source: FixtureSource(name, path, found.line),
          kind: found.kind,
          expect: Expectation.unreviewed,
          document: found.document,
        ),
      );
    }
  }
  return fixtures;
}

/// How a harvest differs from the committed corpus.
class CorpusDiff {
  /// Compares [harvested] fixtures with the [committed] corpus.
  factory CorpusDiff(Corpus committed, Iterable<Fixture> harvested) {
    final fresh = Corpus(harvested).fixtures;
    final added = <Fixture>[];
    final moved = <(Fixture, Fixture)>[];
    for (final MapEntry(:key, value: fixture) in fresh.entries) {
      final old = committed.fixtures[key];
      if (old == null) {
        added.add(fixture);
      } else if (old.source.line != fixture.source.line ||
          old.kind != fixture.kind) {
        moved.add((old, fixture));
      }
    }
    final removed = [
      for (final MapEntry(:key, :value) in committed.fixtures.entries)
        if (!fresh.containsKey(key)) value,
    ];
    return CorpusDiff._(
      added..sort(compareSources),
      removed..sort(compareSources),
      moved..sort((a, b) => compareSources(a.$2, b.$2)),
    );
  }

  CorpusDiff._(this.added, this.removed, this.moved);

  /// Documents found upstream that the corpus lacks.
  final List<Fixture> added;

  /// Corpus fixtures no longer found upstream.
  final List<Fixture> removed;

  /// Unchanged documents found at another line, as (committed, harvested).
  final List<(Fixture, Fixture)> moved;

  /// Whether the harvest matches the corpus.
  bool get isEmpty => added.isEmpty && removed.isEmpty && moved.isEmpty;

  /// A Markdown report of the differences, with what Dart does with each
  /// new document. [commits] are the harvested commits by repository.
  String report(RefsLock lock, Map<String, String> commits) {
    final buffer = StringBuffer()
      ..writeln('The UTCP documents upstream no longer match the conformance')
      ..writeln('corpus in `packages/utcp_conformance/fixtures`.')
      ..writeln()
      ..writeln('| Repository | Corpus (`refs.lock`) | Harvested |')
      ..writeln('| --- | --- | --- |');
    for (final MapEntry(key: name, value: ref) in lock.repos.entries) {
      final base = ref.url.replaceAll(RegExp(r'\.git$'), '');
      final now = commits[name] ?? ref.commit;
      buffer.writeln(
        '| $name | [`${ref.commit.substring(0, 7)}`]($base/tree/${ref.commit}) '
        '| [`${now.substring(0, 7)}`]($base/tree/$now) |',
      );
    }
    String where(Fixture f, [String? commit]) {
      final ref = lock.repos[f.source.repo];
      final label = '`${f.source}` (${f.kind.wire})';
      if (ref == null) return label;
      final base = ref.url.replaceAll(RegExp(r'\.git$'), '');
      final sha = commit ?? commits[f.source.repo] ?? ref.commit;
      return '[$label]($base/blob/$sha/${f.source.path}#L${f.source.line})';
    }

    void section(String title, Iterable<String> lines) {
      final items = lines.toList();
      if (items.isEmpty) return;
      buffer
        ..writeln()
        ..writeln('### $title (${items.length})')
        ..writeln();
      items.forEach(buffer.writeln);
    }

    section('New or changed documents', [
      for (final f in added)
        '- ${where(f)}: Dart ${Outcome.of(f.kind, f.document).summary}',
    ]);
    section('Documents gone or changed upstream', [
      for (final f in removed)
        '- ${where(f, lock.repos[f.source.repo]?.commit)}: was '
            '${f.expect.name}${f.reason.isEmpty ? '' : ' (${f.reason})'}',
    ]);
    section('Documents that moved', [
      for (final (old, now) in moved)
        '- ${where(now)}: was line ${old.source.line}'
            '${old.kind == now.kind ? '' : ', kind ${old.kind.wire}'}',
    ]);
    buffer
      ..writeln()
      ..writeln('To update the corpus, in `packages/utcp_conformance` run')
      ..writeln('`dart run tool/harvest.dart --head --write`, set `expect`,')
      ..writeln('`reason` and `may_drop` on each new fixture, carry over the')
      ..writeln('review of any changed one, and run `dart test`.');
    return buffer.toString();
  }
}
