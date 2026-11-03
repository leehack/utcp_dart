import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/release.dart';

String pubspec(String name, String version, {String? utcp}) =>
    '''
name: $name
version: $version

environment:
  sdk: ^3.8.0

resolution: workspace

dependencies:
  http: ^1.6.0
${utcp == null ? '' : '  utcp: $utcp\n'}
dev_dependencies:
  test: ^1.26.0
''';

const unreleased =
    '# Changelog\n\n## Unreleased\n\n- New.\n\n## 0.1.0\n\n- Old.\n';

void main() {
  group('Version', () {
    test('parses and prints semantic versions', () {
      for (final text in ['0.2.1', '1.0.0-dev.1', '1.2.3+4', '1.0.0-rc.1+b']) {
        expect(Version.parse(text).toString(), text);
      }
    });

    test('rejects text that is not a semantic version', () {
      for (final text in ['', '1.2', '1.2.3.4', '01.2.3', 'v1.2.3', '1.2.3-']) {
        expect(() => Version.parse(text), throwsFormatException, reason: text);
      }
    });

    test('orders pre-releases before their release', () {
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0',
        '1.0.1',
        '1.1.0',
        '2.0.0',
      ].map(Version.parse).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(ordered[i - 1].compareTo(ordered[i]), lessThan(0));
      }
    });

    test('bumps each level', () {
      String bump(String version, String level) =>
          Version.parse(version).bump(level).toString();
      expect(bump('0.2.1', 'patch'), '0.2.2');
      expect(bump('0.2.1', 'minor'), '0.3.0');
      expect(bump('0.2.1', 'major'), '1.0.0');
      expect(bump('1.0.0-dev.1', 'patch'), '1.0.0');
      expect(bump('1.0.0-dev.1', 'major'), '1.0.0');
      expect(bump('1.2.3-dev', 'minor'), '1.3.0');
    });

    test('rejects an unknown level', () {
      expect(
        () => Version.parse('0.1.0').bump('huge'),
        throwsA(isA<ReleaseException>()),
      );
    });
  });

  group('constraintAllows', () {
    bool allows(String constraint, String version) =>
        constraintAllows(constraint, Version.parse(version));

    test('caret below 1.0 admits only the same minor', () {
      expect(allows('^0.2.0', '0.2.1'), isTrue);
      expect(allows('^0.2.0', '0.3.0'), isFalse);
      expect(allows('^0.2.1', '0.2.0'), isFalse);
      expect(allows('^0.0.3', '0.0.4'), isFalse);
    });

    test('caret from 1.0 admits the same major', () {
      expect(allows('^1.2.0', '1.9.0'), isTrue);
      expect(allows('^1.2.0', '2.0.0'), isFalse);
      expect(allows('^1.2.0', '2.0.0-dev'), isFalse);
    });

    test('ranges, exact versions and any', () {
      expect(allows('>=0.2.0 <0.4.0', '0.3.5'), isTrue);
      expect(allows('>=0.2.0 <0.4.0', '0.4.0'), isFalse);
      expect(allows('>0.2.0 <=0.3.0', '0.2.0'), isFalse);
      expect(allows('>0.2.0 <=0.3.0', '0.3.0'), isTrue);
      expect(allows('0.2.1', '0.2.1'), isTrue);
      expect(allows('0.2.1', '0.2.2'), isFalse);
      expect(allows('any', '9.9.9'), isTrue);
    });

    test('rejects a malformed constraint', () {
      expect(() => allows('~>1.0', '1.0.0'), throwsFormatException);
      expect(() => allows('', '1.0.0'), throwsFormatException);
    });
  });

  group('pubspec', () {
    test('reads and sets the version', () {
      final updated = setPubspecVersion(
        pubspec('utcp', '0.2.1'),
        Version.parse('0.3.0'),
      );
      expect(pubspecField(updated, 'version'), '0.3.0');
      expect(pubspecField(updated, 'name'), 'utcp');
    });

    test('reads and sets the utcp constraint under dependencies only', () {
      final withCore = pubspec('utcp_mcp', '0.1.1', utcp: "'^0.2.0'");
      expect(coreConstraint(withCore), '^0.2.0');
      final updated = setCoreConstraint(withCore, '^0.3.0');
      expect(coreConstraint(updated), '^0.3.0');
      expect(updated, contains('  http: ^1.6.0'));

      const devOnly = 'name: x\ndev_dependencies:\n  utcp: ^0.2.0\n';
      expect(coreConstraint(devOnly), isNull);
    });

    test('rejects a utcp dependency that is not a version constraint', () {
      const pathDependency =
          'name: x\ndependencies:\n  utcp:\n    path: ../utcp\n';
      expect(() => coreConstraint(pathDependency), throwsFormatException);
    });
  });

  group('changelog', () {
    test('stamps the Unreleased section', () {
      final stamped = stampChangelog(unreleased, Version.parse('0.2.0'));
      expect(firstChangelogHeading(stamped), '0.2.0');
      expect(stamped, contains('## 0.2.0\n\n- New.\n\n## 0.1.0'));
    });

    test('rejects a changelog without Unreleased first', () {
      expect(
        () => stampChangelog('## 0.1.0\n\n- Old.\n', Version.parse('0.2.0')),
        throwsFormatException,
      );
      expect(
        () => stampChangelog(
          '## 0.1.0\n\n- Old.\n\n## Unreleased\n\n- New.\n',
          Version.parse('0.2.0'),
        ),
        throwsFormatException,
      );
    });

    test('rejects an empty Unreleased section', () {
      expect(
        () => stampChangelog(
          '## Unreleased\n\n## 0.1.0\n\n- Old.\n',
          Version.parse('0.2.0'),
        ),
        throwsFormatException,
      );
    });
  });

  group('prepareRelease', () {
    Map<String, PackageFiles> workspace({String coreChangelog = unreleased}) =>
        {
          'utcp': PackageFiles(
            pubspec: pubspec('utcp', '0.2.1'),
            changelog: coreChangelog,
          ),
          'utcp_mcp': PackageFiles(
            pubspec: pubspec('utcp_mcp', '0.1.1', utcp: '^0.2.0'),
            changelog: unreleased,
          ),
          'utcp_cli': PackageFiles(
            pubspec: pubspec('utcp_cli', '0.1.1', utcp: '^0.2.0'),
            changelog: unreleased,
          ),
        };

    test('a utcp patch keeps transport constraints', () {
      final result = prepareRelease(workspace(), {'utcp': 'patch'});
      expect(result.versions, {'utcp': Version.parse('0.2.2')});
      expect(result.files.keys, ['utcp']);
      expect(firstChangelogHeading(result.files['utcp']!.changelog), '0.2.2');
    });

    test('a utcp minor below 1.0 bumps the released transports', () {
      final result = prepareRelease(workspace(), {
        'utcp': 'minor',
        'utcp_mcp': 'patch',
        'utcp_cli': 'minor',
      });
      expect(result.versions, {
        'utcp': Version.parse('0.3.0'),
        'utcp_mcp': Version.parse('0.1.2'),
        'utcp_cli': Version.parse('0.2.0'),
      });
      for (final name in ['utcp_mcp', 'utcp_cli']) {
        expect(coreConstraint(result.files[name]!.pubspec), '^0.3.0');
      }
    });

    test('a utcp minor requires every dependent to be released', () {
      expect(
        () =>
            prepareRelease(workspace(), {'utcp': 'minor', 'utcp_mcp': 'patch'}),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            allOf(contains('utcp_cli'), isNot(contains('utcp_mcp'))),
          ),
        ),
      );
    });

    test('reports every problem at once', () {
      expect(
        () => prepareRelease(workspace(coreChangelog: '## 0.2.1\n\n- Old.\n'), {
          'utcp': 'patch',
          'utcp_mcp': 'tiny',
          'utcp_nope': 'patch',
        }),
        throwsA(
          isA<ReleaseException>()
              .having((e) => e.message.split('\n'), 'lines', [
                startsWith('utcp:'),
                startsWith('utcp_mcp:'),
                startsWith('utcp_nope:'),
              ]),
        ),
      );
    });

    test('names the branch after utcp, or the date without it', () {
      final today = DateTime(2026, 11, 3);
      expect(
        prepBranch({'utcp': Version.parse('0.3.0')}, today),
        'release/prep-0.3.0',
      );
      expect(
        prepBranch({'utcp_mcp': Version.parse('0.1.2')}, today),
        'release/prep-2026-11-03',
      );
    });
  });

  group('releaseProblems', () {
    List<String> problems(
      String version,
      String changelog, {
      String? utcp,
      List<String> available = const ['0.1.0', '0.2.0'],
    }) => releaseProblems(
      name: 'utcp_mcp',
      version: version,
      files: PackageFiles(
        pubspec: pubspec('utcp_mcp', version, utcp: utcp),
        changelog: changelog,
      ),
      availableCore: available.map(Version.parse),
    );

    test('accepts a stamped changelog and a satisfiable constraint', () {
      expect(
        problems('0.1.1', '## 0.1.1\n\n- New.\n', utcp: '^0.2.0'),
        isEmpty,
      );
    });

    test('accepts a constraint only the released utcp admits', () {
      expect(
        problems(
          '0.2.0',
          '## 0.2.0\n\n- New.\n',
          utcp: '^0.3.0',
          available: ['0.2.0', '0.3.0'],
        ),
        isEmpty,
      );
    });

    test('rejects an invalid version', () {
      expect(problems('0.1', '## 0.1\n'), [contains('not a semantic')]);
    });

    test('rejects Unreleased left above the version', () {
      expect(
        problems('0.1.1', '## Unreleased\n\n- X.\n\n## 0.1.1\n\n- New.\n'),
        [contains('"## Unreleased", not "## 0.1.1"')],
      );
      expect(problems('0.1.1', '# Changelog\n'), [contains('missing')]);
    });

    test('rejects a constraint no utcp version satisfies', () {
      expect(problems('0.1.1', '## 0.1.1\n', utcp: '^0.3.0'), [
        contains('admits no utcp version'),
      ]);
    });
  });

  group('readPackages', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('release_test_');
    });
    tearDown(() => root.delete(recursive: true));

    void writePackage(String dir, String pubspec) {
      File('${root.path}/packages/$dir/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(pubspec);
    }

    test('skips packages that are not published', () {
      writePackage('utcp', pubspec('utcp', '0.2.1'));
      writePackage(
        'utcp_conformance',
        'name: utcp_conformance\npublish_to: none\n',
      );
      expect(readPackages(root).keys, ['utcp']);
    });

    test('rejects a package not named after its directory', () {
      writePackage('utcp_x', pubspec('utcp_y', '0.1.0'));
      expect(() => readPackages(root), throwsA(isA<ReleaseException>()));
    });
  });
}
