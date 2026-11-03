// Prepares a release-prep PR: bumps package versions, stamps their
// changelogs, and prints the branch and the commands that open the PR.
//
//   dart run tool/prepare_release.dart utcp:patch utcp_mcp:minor
import 'dart:io';

import 'src/release.dart';

void main(List<String> args) {
  const usage =
      'Usage: dart run tool/prepare_release.dart '
      '<package>:<major|minor|patch>...';
  final bumps = <String, String>{};
  for (final arg in args) {
    final parts = arg.split(':');
    if (parts.length != 2 || parts[1].isEmpty || bumps.containsKey(parts[0])) {
      _fail('$usage\nName each package once; got "$arg".', 64);
    }
    bumps[parts[0]] = parts[1];
  }
  if (bumps.isEmpty) _fail(usage, 64);
  if (!File('pubspec.yaml').existsSync() ||
      !Directory('packages').existsSync()) {
    _fail('Run this from the repository root.', 64);
  }

  final ({Map<String, PackageFiles> files, Map<String, Version> versions})
  result;
  try {
    result = prepareRelease(readPackages(Directory.current), bumps);
  } on ReleaseException catch (error) {
    _fail('Nothing was changed:\n$error', 1);
  }

  for (final MapEntry(key: name, value: files) in result.files.entries) {
    File('packages/$name/pubspec.yaml').writeAsStringSync(files.pubspec);
    File('packages/$name/CHANGELOG.md').writeAsStringSync(files.changelog);
  }

  final branch = prepBranch(result.versions, DateTime.now());
  final released = [
    for (final MapEntry(key: name, value: version) in result.versions.entries)
      '$name $version',
  ];
  final title = 'Release ${released.join(', ')}';
  stdout.writeln(
    '''
$title

Branch: $branch

Review the diff, then:
  git switch -c $branch
  git commit -am "$title"
  git push -u origin $branch
  gh pr create --base main --head $branch --label release-prep --title "$title" --body "Merging publishes these versions to pub.dev."''',
  );
}

Never _fail(String message, int code) {
  stderr.writeln(message);
  exit(code);
}
