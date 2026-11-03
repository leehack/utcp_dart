// Prints `<package> <version>` for every package whose version is not on
// pub.dev, utcp first, after checking each can be published. Used by
// .github/workflows/release_on_prep_merge.yml; run from the repository root.
import 'dart:convert';
import 'dart:io';

import 'src/release.dart';

Future<void> main() async {
  final packages = readPackages(Directory.current);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final published = <String, List<Version>>{};
  final pending = <String, String>{};
  try {
    for (final MapEntry(key: name, value: files) in packages.entries) {
      final version = pubspecField(files.pubspec, 'version') ?? '';
      final listing = await _get(client, 'https://pub.dev/api/packages/$name');
      if (listing.status == 404) {
        _fail(
          '$name is not on pub.dev. Automated publishing cannot create a '
          'package: publish its first version by hand, then configure '
          'automated publishing for it (see AGENTS.md).',
        );
      }
      published[name] = _versions(name, listing);
      final status = (await _get(
        client,
        'https://pub.dev/api/packages/$name/versions/$version',
      )).status;
      if (status == 404) {
        pending[name] = version;
      } else {
        stderr.writeln('$name $version is already on pub.dev.');
      }
    }
  } finally {
    client.close();
  }

  final availableCore = [
    ...?published[corePackage],
    ?Version.tryParse(pending[corePackage]),
  ];
  final problems = [
    for (final MapEntry(key: name, value: version) in pending.entries)
      ...releaseProblems(
        name: name,
        version: version,
        files: packages[name]!,
        availableCore: availableCore,
      ),
  ];
  if (problems.isNotEmpty) _fail(problems.join('\n'));

  final order = [
    if (pending.containsKey(corePackage)) corePackage,
    ...pending.keys.where((name) => name != corePackage),
  ];
  for (final name in order) {
    stdout.writeln('$name ${pending[name]}');
  }
}

Future<({int status, String body})> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200 && response.statusCode != 404) {
    _fail('pub.dev answered HTTP ${response.statusCode} for $url.');
  }
  return (status: response.statusCode, body: body);
}

List<Version> _versions(String name, ({int status, String body}) listing) {
  if (jsonDecode(listing.body) case {'versions': final List<Object?> entries}) {
    return [
      for (final entry in entries)
        if (entry case {'version': final String version})
          Version.parse(version),
    ];
  }
  _fail('pub.dev listing for $name has no versions.');
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
