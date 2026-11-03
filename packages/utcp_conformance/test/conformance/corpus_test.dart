@Tags(['conformance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

void main() {
  final corpus = Corpus.read(Directory('fixtures'));
  final lock = RefsLock.read(File('refs.lock'));
  late List<CommunicationProtocol> protocols;

  setUpAll(() => protocols = registerAllProtocols());
  tearDownAll(() async {
    for (final protocol in protocols) {
      await protocol.close();
    }
  });

  group('fixture', () {
    for (final fixture in corpus.ordered) {
      test('${fixture.source} (${fixture.kind.wire}, ${fixture.id})', () {
        final found = problems(
          fixture,
          Outcome.of(fixture.kind, fixture.document),
        );
        if (fixture.knownFailure case final bug?) {
          expect(
            found,
            isNotEmpty,
            reason: 'Fixed: "$bug". Remove known_failure from ${fixture.id}.',
          );
        } else {
          expect(found, isEmpty, reason: fixture.reason);
        }
      });
    }
  });

  group('corpus', () {
    test('covers every source repository in refs.lock', () {
      final repos = {for (final f in corpus.fixtures.values) f.source.repo};
      expect(repos, unorderedEquals(lock.repos.keys));
    });

    test('says why for every fixture', () {
      final missing = [
        for (final f in corpus.ordered)
          if (f.reason.trim().isEmpty) f.id,
      ];
      expect(missing, isEmpty);
    });

    test('names each fixture after its document', () {
      final stale = [
        for (final f in corpus.ordered)
          if (f.id != fixtureId(f.source.path, f.document)) f.id,
      ];
      expect(stale, isEmpty, reason: 'Edit upstream, not the fixture.');
    });

    test('keeps fixture files in the form the harvester writes', () {
      const encoder = JsonEncoder.withIndent('  ');
      for (final f in corpus.fixtures.values) {
        final file = File('fixtures/${f.source.repo}/${f.id}.json');
        expect(
          file.readAsStringSync(),
          '${encoder.convert(f.toJson())}\n',
          reason: file.path,
        );
      }
    });
  });

  group('utcpProtocolVersion', () {
    test('is the spec version in refs.lock', () {
      expect(utcpProtocolVersion, startsWith('${lock.specVersion}.'));
    });

    test('is what manuals are written with', () {
      expect(
        const UtcpManual(tools: []).toJson()['utcp_version'],
        utcpProtocolVersion,
      );
      expect(
        UtcpManual.fromJson({'tools': <Object?>[]}).utcpVersion,
        utcpProtocolVersion,
      );
      final converted = OpenApiConverter({
        'openapi': '3.0.0',
        'info': {'title': 'Pets', 'version': '1.0.0'},
        'servers': [
          {'url': 'https://pets.example.com'},
        ],
        'paths': {
          '/pets': {
            'get': {'operationId': 'listPets'},
          },
        },
      }).convert();
      expect(converted.tools, isNotEmpty);
      expect(converted.toJson()['utcp_version'], utcpProtocolVersion);
    });
  });

  test('the README spec table names the spec version and refs.lock', () {
    final readme = File('../../README.md').readAsStringSync();
    expect(readme, contains('| $utcpProtocolVersion |'));
    for (final ref in lock.repos.values) {
      expect(readme, contains(ref.commit.substring(0, 7)));
    }
  });
}
