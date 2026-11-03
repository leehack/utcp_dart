/// Release logic shared by `tool/prepare_release.dart` and
/// `tool/release_plan.dart`.
library;

import 'dart:io';

/// The core package every transport package depends on.
const corePackage = 'utcp';

/// A release-tooling failure to report to the person running the tool.
class ReleaseException implements Exception {
  /// Creates an exception with one problem per line in [message].
  ReleaseException(this.message);

  /// Every problem found, one per line.
  final String message;

  @override
  String toString() => message;
}

const _numeric = r'(?:0|[1-9]\d*)';
const _preReleaseId = '(?:$_numeric|\\d*[A-Za-z-][0-9A-Za-z-]*)';
final _semver = RegExp(
  '^($_numeric)\\.($_numeric)\\.($_numeric)'
  '(?:-($_preReleaseId(?:\\.$_preReleaseId)*))?'
  r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
);

/// A semantic version, ordered as pub orders versions (build ignored).
class Version implements Comparable<Version> {
  /// Creates `major.minor.patch[-preRelease][+build]`.
  Version(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
    this.build,
  });

  /// Parses a semantic version, throwing a [FormatException] if [text] is
  /// not one.
  factory Version.parse(String text) {
    final match = _semver.firstMatch(text);
    if (match == null) {
      throw FormatException('"$text" is not a semantic version');
    }
    return Version(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      preRelease: match[4]?.split('.') ?? const [],
      build: match[5],
    );
  }

  /// Parses [text], or returns `null` if it is not a semantic version.
  static Version? tryParse(String? text) {
    if (text == null) return null;
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// The major version.
  final int major;

  /// The minor version.
  final int minor;

  /// The patch version.
  final int patch;

  /// Dot-separated pre-release identifiers; empty for a stable version.
  final List<String> preRelease;

  /// Build metadata, if any.
  final String? build;

  /// Whether this is a pre-release.
  bool get isPreRelease => preRelease.isNotEmpty;

  /// The next version at [level] (`major`, `minor` or `patch`). As in pub, a
  /// pre-release bumps to its own stable version when that is the next one.
  Version bump(String level) => switch (level) {
    'major' =>
      isPreRelease && minor == 0 && patch == 0
          ? Version(major, 0, 0)
          : Version(major + 1, 0, 0),
    'minor' =>
      isPreRelease && patch == 0
          ? Version(major, minor, 0)
          : Version(major, minor + 1, 0),
    'patch' =>
      isPreRelease
          ? Version(major, minor, patch)
          : Version(major, minor, patch + 1),
    _ => throw ReleaseException(
      'Unknown bump "$level"; use major, minor or patch.',
    ),
  };

  /// The exclusive upper bound of `^this`.
  Version get caretUpperBound => major > 0
      ? Version(major + 1, 0, 0)
      : minor > 0
      ? Version(0, minor + 1, 0)
      : Version(0, 0, patch + 1);

  bool _sameRelease(Version other) =>
      major == other.major && minor == other.minor && patch == other.patch;

  @override
  int compareTo(Version other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    if (isPreRelease != other.isPreRelease) return isPreRelease ? -1 : 1;
    for (var i = 0; i < preRelease.length && i < other.preRelease.length; i++) {
      final order = _compareIdentifier(preRelease[i], other.preRelease[i]);
      if (order != 0) return order;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  static int _compareIdentifier(String a, String b) {
    final numberA = int.tryParse(a);
    final numberB = int.tryParse(b);
    if (numberA != null && numberB != null) return numberA.compareTo(numberB);
    if (numberA != null) return -1;
    if (numberB != null) return 1;
    return a.compareTo(b);
  }

  @override
  bool operator ==(Object other) =>
      other is Version && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() =>
      '$major.$minor.$patch'
      '${isPreRelease ? '-${preRelease.join('.')}' : ''}'
      '${build == null ? '' : '+$build'}';
}

final _bound = RegExp(r'^(\^|>=|<=|>|<)?(.+)$');

/// Whether the pub version [constraint] admits [version].
///
/// Supports `any`, an exact version, `^x.y.z`, and `>=`, `>`, `<=` and `<`
/// bounds separated by spaces. Throws a [FormatException] for anything else.
bool constraintAllows(String constraint, Version version) {
  final text = constraint.trim();
  if (text == 'any') return true;
  if (text.isEmpty) throw const FormatException('Empty version constraint');
  return text.split(RegExp(r'\s+')).every((part) {
    final match = _bound.firstMatch(part)!;
    final bound = Version.parse(match[2]!);
    final order = version.compareTo(bound);
    return switch (match[1]) {
      '^' => order >= 0 && _below(version, bound.caretUpperBound),
      '>=' => order >= 0,
      '>' => order > 0,
      '<=' => order <= 0,
      '<' => _below(version, bound),
      _ => order == 0,
    };
  });
}

// Like pub, `<2.0.0` also excludes the pre-releases of 2.0.0.
bool _below(Version version, Version max) =>
    version.compareTo(max) < 0 &&
    !(version.isPreRelease && !max.isPreRelease && version._sameRelease(max));

/// The value of the top-level [field] in [pubspec], if present.
String? pubspecField(String pubspec, String field) => RegExp(
  '^$field:[ \\t]*(\\S+)[ \\t]*\$',
  multiLine: true,
).firstMatch(pubspec)?[1];

/// [pubspec] with its top-level `version:` set to [version].
String setPubspecVersion(String pubspec, Version version) {
  final line = RegExp(r'^version:.*$', multiLine: true);
  if (!line.hasMatch(pubspec)) {
    throw const FormatException('pubspec.yaml has no top-level version');
  }
  return pubspec.replaceFirst(line, 'version: $version');
}

final _dependencyEntry = RegExp(r'^([ \t]+)utcp:[ \t]*(.*?)[ \t]*$');

int? _coreDependencyLine(List<String> lines) {
  var inDependencies = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isNotEmpty && !line.startsWith(RegExp(r'[ \t#]'))) {
      inDependencies = line.startsWith('dependencies:');
    } else if (inDependencies && _dependencyEntry.hasMatch(line)) {
      return i;
    }
  }
  return null;
}

/// The version constraint on `utcp` under `dependencies:` in [pubspec], or
/// `null` if the package does not depend on it.
String? coreConstraint(String pubspec) {
  final lines = pubspec.split('\n');
  final index = _coreDependencyLine(lines);
  if (index == null) return null;
  final value = _dependencyEntry.firstMatch(lines[index])![2]!;
  final constraint = value.replaceAll(RegExp('^[\'"]|[\'"]\$'), '');
  if (constraint.isEmpty) {
    throw const FormatException(
      'The utcp dependency must be a hosted version constraint',
    );
  }
  return constraint;
}

/// [pubspec] with its `utcp` dependency constrained to [constraint].
String setCoreConstraint(String pubspec, String constraint) {
  final lines = pubspec.split('\n');
  final index = _coreDependencyLine(lines);
  if (index == null) {
    throw const FormatException('pubspec.yaml does not depend on utcp');
  }
  final indent = _dependencyEntry.firstMatch(lines[index])![1]!;
  lines[index] = '${indent}utcp: $constraint';
  return lines.join('\n');
}

/// The first `## ` heading of [changelog] without its `## `, or `null`.
String? firstChangelogHeading(String changelog) {
  for (final line in changelog.split('\n')) {
    if (line.startsWith('## ')) return line.substring(3).trim();
  }
  return null;
}

/// [changelog] with its leading `## Unreleased` section renamed to
/// `## <version>`.
///
/// Throws a [FormatException] if the first section is not `## Unreleased`
/// or has no entries.
String stampChangelog(String changelog, Version version) {
  final lines = changelog.split('\n');
  final start = lines.indexWhere((line) => line.startsWith('## '));
  if (start < 0 || lines[start].trim() != '## Unreleased') {
    throw const FormatException(
      'CHANGELOG.md must start with a "## Unreleased" section',
    );
  }
  final hasEntries = lines
      .skip(start + 1)
      .takeWhile((line) => !line.startsWith('## '))
      .any((line) => line.trim().isNotEmpty);
  if (!hasEntries) {
    throw const FormatException('"## Unreleased" in CHANGELOG.md is empty');
  }
  lines[start] = '## $version';
  return lines.join('\n');
}

/// The release files of one workspace package.
class PackageFiles {
  /// Creates the files of a package.
  const PackageFiles({required this.pubspec, required this.changelog});

  /// The contents of `pubspec.yaml`.
  final String pubspec;

  /// The contents of `CHANGELOG.md`.
  final String changelog;
}

/// Applies [bumps] (package name to `major`, `minor` or `patch`) to
/// [packages] (package name to files).
///
/// Returns the changed packages and their new versions. When the new `utcp`
/// is outside a dependent's constraint, the constraint becomes `^<new>`,
/// and that dependent must be bumped too. Throws a [ReleaseException]
/// listing every problem; nothing is returned in that case.
({Map<String, PackageFiles> files, Map<String, Version> versions})
prepareRelease(Map<String, PackageFiles> packages, Map<String, String> bumps) {
  final problems = <String>[];
  final files = <String, PackageFiles>{};
  final versions = <String, Version>{};

  for (final MapEntry(key: name, value: level) in bumps.entries) {
    final package = packages[name];
    if (package == null) {
      problems.add('$name: no such package under packages/.');
      continue;
    }
    final version = pubspecField(package.pubspec, 'version');
    if (version == null) {
      problems.add('$name: pubspec.yaml has no top-level version.');
      continue;
    }
    try {
      final current = Version.parse(version);
      final next = current.bump(level);
      files[name] = PackageFiles(
        pubspec: setPubspecVersion(package.pubspec, next),
        changelog: stampChangelog(package.changelog, next),
      );
      versions[name] = next;
    } on FormatException catch (error) {
      problems.add('$name: ${error.message}.');
    } on ReleaseException catch (error) {
      problems.add('$name: ${error.message}');
    }
  }

  final core = versions[corePackage];
  if (core != null) {
    for (final MapEntry(key: name, value: package) in packages.entries) {
      final current = files[name] ?? package;
      try {
        final constraint = coreConstraint(current.pubspec);
        if (constraint == null || constraintAllows(constraint, core)) continue;
        if (!versions.containsKey(name)) {
          problems.add(
            '$name: its utcp constraint $constraint does not admit utcp '
            '$core; add $name:<major|minor|patch> to release it with ^$core.',
          );
          continue;
        }
        files[name] = PackageFiles(
          pubspec: setCoreConstraint(current.pubspec, '^$core'),
          changelog: current.changelog,
        );
      } on FormatException catch (error) {
        problems.add('$name: ${error.message}.');
      }
    }
  }

  if (problems.isNotEmpty) throw ReleaseException(problems.join('\n'));
  return (files: files, versions: versions);
}

/// The problems that block publishing [name] at [version] from [files], or
/// an empty list.
///
/// The changelog must start with `## <version>`. If the package depends on
/// `utcp`, its constraint must admit one of [availableCore]: the `utcp`
/// versions on pub.dev plus the one this release publishes.
List<String> releaseProblems({
  required String name,
  required String version,
  required PackageFiles files,
  required Iterable<Version> availableCore,
}) {
  try {
    Version.parse(version);
  } on FormatException catch (error) {
    return ['$name: ${error.message}.'];
  }
  final problems = <String>[];
  final heading = firstChangelogHeading(files.changelog);
  if (heading != version) {
    problems.add(
      '$name: the first heading in CHANGELOG.md is '
      '${heading == null ? 'missing' : '"## $heading"'}, not "## $version".',
    );
  }
  try {
    final constraint = coreConstraint(files.pubspec);
    if (constraint != null &&
        !availableCore.any((v) => constraintAllows(constraint, v))) {
      problems.add(
        '$name: its utcp constraint $constraint admits no utcp version on '
        'pub.dev or in this release (${availableCore.join(', ')}).',
      );
    }
  } on FormatException catch (error) {
    problems.add('$name: utcp constraint: ${error.message}.');
  }
  return problems;
}

/// The `release/prep-*` branch for a release of [versions]: named after the
/// new `utcp` version, or after [today] when `utcp` is not released.
String prepBranch(Map<String, Version> versions, DateTime today) {
  String pad(int n) => n.toString().padLeft(2, '0');
  final core = versions[corePackage];
  return 'release/prep-'
      '${core ?? '${today.year}-${pad(today.month)}-${pad(today.day)}'}';
}

/// The packages under `packages/` of [root], by name. Each lives in
/// `packages/<name>`.
Map<String, PackageFiles> readPackages(Directory root) {
  final packages = <String, PackageFiles>{};
  final dirs =
      Directory('${root.path}/packages')
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path.split(Platform.pathSeparator).last)
          .toList()
        ..sort();
  for (final dir in dirs) {
    final pubspec = File('${root.path}/packages/$dir/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final contents = pubspec.readAsStringSync();
    final name = pubspecField(contents, 'name');
    if (name != dir) {
      throw ReleaseException(
        '${pubspec.path} must be named after its directory, not "$name".',
      );
    }
    final changelog = File('${root.path}/packages/$dir/CHANGELOG.md');
    packages[dir] = PackageFiles(
      pubspec: contents,
      changelog: changelog.existsSync() ? changelog.readAsStringSync() : '',
    );
  }
  return packages;
}
