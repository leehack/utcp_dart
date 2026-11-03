import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';

import 'extract.dart';

/// What Dart must do with a fixture's document.
enum Expectation {
  /// Parse it, and round-trip it without dropping fields outside `may_drop`.
  accept,

  /// Fail to parse it with a `FormatException`.
  reject,

  /// Not reviewed yet: a harvested document nobody has judged. The corpus
  /// test fails until it is set to [accept] or [reject].
  unreviewed;

  /// The expectation spelled [wire], or a [FormatException].
  static Expectation parse(String wire) =>
      values.asNameMap()[wire] ??
      (throw FormatException("Unknown expectation '$wire'."));
}

/// Where a fixture's document was found upstream.
class FixtureSource {
  /// Creates a source at [path]:[line] of [repo].
  const FixtureSource(this.repo, this.path, this.line);

  /// Reads a fixture's `source` object.
  factory FixtureSource.fromJson(JsonMap json) => FixtureSource(
    json.string('repo'),
    json.string('path'),
    json.optInt('line') ??
        (throw const FormatException("Missing required 'line'.")),
  );

  /// The repository name, as in `refs.lock`.
  final String repo;

  /// The file, relative to the repository root.
  final String path;

  /// The 1-based line the document starts on.
  final int line;

  /// The JSON form read by [FixtureSource.fromJson].
  JsonMap toJson() => {'repo': repo, 'path': path, 'line': line};

  @override
  String toString() => '$repo/$path:$line';
}

/// One harvested UTCP document and what Dart must do with it.
class Fixture {
  /// Creates a fixture.
  const Fixture({
    required this.id,
    required this.source,
    required this.kind,
    required this.expect,
    required this.document,
    this.reason = '',
    this.mayDrop = const [],
    this.knownFailure,
    this.rejectError,
  });

  /// Reads the fixture file named [id].
  factory Fixture.fromJson(String id, JsonMap json) => Fixture(
    id: id,
    source: FixtureSource.fromJson(json.object('source')),
    kind: DocumentKind.parse(json.string('kind')),
    expect: Expectation.parse(json.string('expect')),
    reason: json.optString('reason') ?? '',
    mayDrop: json.optStringList('may_drop') ?? const [],
    knownFailure: json.optString('known_failure'),
    rejectError: json.optString('reject_error'),
    document: json.object('document'),
  );

  /// The file name without `.json`: the source path and a hash of the
  /// document, so it survives line moves and changes with the content.
  final String id;

  /// Where the document was found.
  final FixtureSource source;

  /// What parses the document.
  final DocumentKind kind;

  /// What Dart must do with the document.
  final Expectation expect;

  /// Why: the spec rule, the reference SDK behaviour or the docs bug.
  final String reason;

  /// Paths (`.`-separated keys, `*` for any key or index) Dart may drop or
  /// rewrite on a round trip. A path covers everything below it.
  final List<String> mayDrop;

  /// Set when Dart does not meet [expect] yet: the Dart bug, briefly. The
  /// corpus test then requires the fixture to fail, so a fix shows up.
  final String? knownFailure;

  /// For a [Expectation.reject] fixture, a substring Dart's error message
  /// must contain, so the document fails for the reason [reason] gives.
  final String? rejectError;

  /// The UTCP document.
  final JsonMap document;

  /// This fixture with its upstream facts replaced by [other]'s and its
  /// review kept.
  Fixture rebase(Fixture other) => Fixture(
    id: id,
    source: other.source,
    kind: other.kind,
    expect: expect,
    reason: reason,
    mayDrop: mayDrop,
    knownFailure: knownFailure,
    rejectError: rejectError,
    document: other.document,
  );

  /// The fixture file contents.
  JsonMap toJson() => {
    'source': source.toJson(),
    'kind': kind.wire,
    'expect': expect.name,
    'reason': reason,
    if (mayDrop.isNotEmpty) 'may_drop': mayDrop,
    'known_failure': ?knownFailure,
    'reject_error': ?rejectError,
    'document': document,
  };
}

/// [value] as JSON with object keys sorted, so equal documents encode
/// equally.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _sorted(map[key]),
  },
  final List<Object?> list => [for (final e in list) _sorted(e)],
  _ => value,
};

/// The fixture id for [document] found in [path].
String fixtureId(String path, JsonMap document) {
  // FNV-1a: ids only need to differ between documents of one file.
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(canonicalJson(document))) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  final slug = path.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '.');
  return '$slug-${hash.toRadixString(16).padLeft(8, '0')}';
}

/// The fixtures under a `fixtures/` directory, one file per fixture in a
/// directory per repository.
class Corpus {
  /// Creates a corpus of [fixtures].
  Corpus(Iterable<Fixture> fixtures)
    : fixtures = {for (final f in fixtures) key(f.source.repo, f.id): f};

  /// Reads every `<repo>/<id>.json` under [dir].
  factory Corpus.read(Directory dir) {
    if (!dir.existsSync()) return Corpus(const []);
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return Corpus([
      for (final file in files)
        _readFixture(
          file,
          file.uri.pathSegments.last.replaceFirst(_suffix, ''),
        ),
    ]);
  }

  static final _suffix = RegExp(r'\.json$');

  static Fixture _readFixture(File file, String id) {
    try {
      return Fixture.fromJson(
        id,
        asJsonMap(jsonDecode(file.readAsStringSync()), file.path),
      );
    } on FormatException catch (error) {
      throw FormatException('${file.path}: ${error.message}');
    }
  }

  /// The corpus key of fixture [id] from [repo].
  static String key(String repo, String id) => '$repo/$id';

  /// Fixtures by [key].
  final Map<String, Fixture> fixtures;

  /// Fixtures ordered by repository, path and line.
  List<Fixture> get ordered => fixtures.values.toList()..sort(compareSources);

  /// This corpus updated to [harvested]: the review of each unchanged
  /// document kept, new documents unreviewed, vanished ones dropped.
  Corpus updatedTo(Iterable<Fixture> harvested) => Corpus([
    for (final fixture in harvested)
      fixtures[key(fixture.source.repo, fixture.id)]?.rebase(fixture) ??
          fixture,
  ]);

  /// Replaces the contents of [dir] with this corpus.
  void write(Directory dir) {
    if (dir.existsSync()) {
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (file.path.endsWith('.json')) file.deleteSync();
      }
    }
    const encoder = JsonEncoder.withIndent('  ');
    for (final fixture in fixtures.values) {
      File('${dir.path}/${fixture.source.repo}/${fixture.id}.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('${encoder.convert(fixture.toJson())}\n');
    }
  }
}

/// Orders fixtures by repository, path, line and id.
int compareSources(Fixture a, Fixture b) {
  for (final order in [
    a.source.repo.compareTo(b.source.repo),
    a.source.path.compareTo(b.source.path),
    a.source.line.compareTo(b.source.line),
  ]) {
    if (order != 0) return order;
  }
  return a.id.compareTo(b.id);
}
