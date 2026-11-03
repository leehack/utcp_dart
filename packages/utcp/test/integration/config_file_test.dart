@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/fake_protocol.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('utcp_config_file_');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<String> write(String name, String content) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  test('reads a JSON config', () async {
    final path = await write(
      'utcp.json',
      jsonEncode({
        'variables': {'A': 'b'},
        'tool_search_strategy': {'tag_weight': 7},
      }),
    );
    final config = await UtcpClientConfig.fromFile(path);
    expect(config.variables, {'A': 'b'});
    expect(
      config.toJson()['tool_search_strategy'],
      containsPair('tag_weight', 7),
    );
  });

  test('reads a YAML config', () async {
    for (final name in ['utcp.yaml', 'UTCP.YML']) {
      final path = await write(name, '''
variables:
  A: b
tool_repository:
  tool_repository_type: in_memory
''');
      final config = await UtcpClientConfig.fromFile(path);
      expect(config.variables, {'A': 'b'}, reason: name);
    }
  });

  test('rejects malformed documents with the path in the error', () async {
    for (final (name, content) in [
      ('bad.json', '{"variables": '),
      ('list.json', '[]'),
      ('bad.yaml', 'variables: [unclosed'),
    ]) {
      final path = await write(name, content);
      await expectLater(
        UtcpClientConfig.fromFile(path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(path),
          ),
        ),
        reason: name,
      );
    }
  });

  test('bounds YAML alias expansion', () async {
    final bomb = StringBuffer('a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n');
    for (var i = 1; i < 10; i++) {
      bomb.writeln('a$i: &a$i [${List.filled(10, '*a${i - 1}').join(', ')}]');
    }
    final path = await write('bomb.yaml', bomb.toString());
    await expectLater(UtcpClientConfig.fromFile(path), throwsFormatException);
  });

  test('a missing file throws a FileSystemException', () async {
    await expectLater(
      UtcpClientConfig.fromFile('${dir.path}/missing.json'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('UtcpClient.fromFile parses with the given protocols', () async {
    final path = await write('utcp.yaml', '''
manual_call_templates:
  - name: m
    call_template_type: fake
''');
    final client = await UtcpClient.fromFile(
      path,
      protocols: [
        FakeProtocol(manual: UtcpManual(tools: [fakeTool('echo')])),
      ],
      environment: const {},
      rootDir: dir.path,
    );
    addTearDown(client.close);
    expect((await client.getTools()).single.name, 'm.echo');
    expect(client.rootDir, dir.path);
  });
}
