@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

void main() {
  late UtcpClient client;
  late Directory temp;
  late FileCommunicationProtocol protocol;

  final manual = {
    'utcp_version': '1.0.1',
    'manual_version': '1.2.0',
    'tools': [
      {
        'name': 'calculator',
        'description': 'Performs basic arithmetic operations',
        'tags': ['math', 'arithmetic'],
        'tool_call_template': {
          'call_template_type': 'file',
          'file_path': 'data/calc.txt',
        },
      },
      {
        'name': 'string_utils',
        'description': 'String manipulation utilities',
        'tags': ['text', 'utilities'],
        'tool_call_template': {
          'call_template_type': 'file',
          'file_path': 'data/strings.txt',
        },
      },
    ],
  };

  setUpAll(
    () async => client = await UtcpClient.create(
      protocols: [FileCommunicationProtocol()],
    ),
  );
  tearDownAll(() => client.close());

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('utcp_file_test_');
    protocol = FileCommunicationProtocol(rootDir: temp.path);
  });
  tearDown(() => temp.delete(recursive: true));

  Future<File> write(String name, String content) async {
    final file = File('${temp.path}/$name');
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<RegisterManualResult> register(String filePath) =>
      protocol.registerManual(
        client,
        FileCallTemplate(name: 'local', filePath: filePath),
      );

  group('discovery', () {
    test('a JSON manual is loaded relative to the root directory', () async {
      await write('manual.json', jsonEncode(manual));
      final result = await register('manual.json');
      expect(result.errors, isEmpty);
      expect(result.manual.manualVersion, '1.2.0');
      expect(result.manual.tools.map((t) => t.name), [
        'calculator',
        'string_utils',
      ]);
      expect(result.manual.tools.first.tags, ['math', 'arithmetic']);
      expect(
        result.manual.tools.first.toolCallTemplate,
        isA<FileCallTemplate>(),
      );
    });

    test('a YAML manual is loaded', () async {
      await write('manual.yml', '''
utcp_version: "1.0.1"
tools:
  - name: calculator
    description: Performs basic arithmetic operations
    tool_call_template:
      call_template_type: file
      file_path: data/calc.txt
''');
      final result = await register('manual.yml');
      expect(result.errors, isEmpty);
      expect(result.manual.tools.single.name, 'calculator');
    });

    test('an absolute path ignores the root directory', () async {
      final file = await write('nested/manual.json', jsonEncode(manual));
      final result = await FileCommunicationProtocol(
        rootDir: '/nonexistent',
      ).registerManual(client, FileCallTemplate(filePath: file.path));
      expect(result.errors, isEmpty);
    });

    for (final (what, name, content, error) in [
      ('a missing file', 'missing.json', null, 'not found'),
      ('invalid JSON', 'bad.json', '{"tools": [', 'Invalid manual file'),
      ('invalid YAML', 'bad.yaml', 'tools: [', 'Invalid manual file'),
      ('a document that is not an object', 'list.json', '[]', 'object'),
      ('an object without tools', 'empty.json', '{}', "'tools'"),
      (
        'a malformed tool',
        'tool.json',
        '{"tools": [{"name": "x"}]}',
        "'tool_call_template'",
      ),
      (
        'an OpenAPI operation without responses',
        'openapi.yaml',
        'openapi: 3.0.0\npaths:\n  /x:\n    get:\n      operationId: x\n'
            '      parameters: 1\n',
        'Invalid manual file',
      ),
    ]) {
      test('$what is a failure', () async {
        if (content != null) await write(name, content);
        final result = await register(name);
        expect(result.success, isFalse);
        expect(result.manual.tools, isEmpty);
        expect(result.errors.single, contains(error));
      });
    }
  });

  group('OpenAPI documents', () {
    test('are converted, with auth_tools applied', () async {
      await write('openapi.yaml', '''
openapi: 3.0.0
info: {title: Pets}
servers: [{url: https://pets.example.com/v1}]
components:
  securitySchemes:
    key: {type: apiKey, in: header, name: X-Api-Key}
security: [{key: []}]
paths:
  /pets/{id}:
    get:
      operationId: getPet
      parameters:
        - {name: id, in: path, required: true, schema: {type: string}}
''');
      final result = await protocol.registerManual(
        client,
        const FileCallTemplate(
          name: 'pets',
          filePath: 'openapi.yaml',
          authTools: ApiKeyAuth(apiKey: 'k'),
        ),
      );
      expect(result.errors, isEmpty);
      final tool = result.manual.tools.single;
      expect(tool.name, 'getPet');
      final template = tool.toolCallTemplate as HttpCallTemplate;
      expect(template.url, 'https://pets.example.com/v1/pets/{id}');
      expect(tool.inputs.required, ['id']);
      expect(
        template.auth,
        isA<ApiKeyAuth>()
            .having((a) => a.apiKey, 'apiKey', 'k')
            .having((a) => a.varName, 'varName', 'X-Api-Key'),
      );
    });

    test('may not point tools at loopback', () async {
      await write(
        'local.json',
        jsonEncode({
          'openapi': '3.0.0',
          'servers': [
            {'url': 'http://localhost:8080'},
          ],
          'paths': {
            '/x': {
              'get': {'operationId': 'x'},
            },
          },
        }),
      );
      final result = await register('local.json');
      expect(result.success, isFalse);
      expect(result.errors.single, contains('loopback'));
    });
  });

  group('UTCP manuals', () {
    Map<String, Object?> httpManual(String url) => {
      'tools': [
        {
          'name': 'x',
          'tool_call_template': {'call_template_type': 'http', 'url': url},
        },
      ],
    };

    test('may not point tools at loopback', () async {
      await write('local.json', jsonEncode(httpManual('http://127.0.0.1/x')));
      final result = await register('local.json');
      expect(result.success, isFalse);
      expect(result.errors.single, contains('loopback'));
    });

    test('may point tools at a remote host', () async {
      await write('remote.json', jsonEncode(httpManual('https://a.example/x')));
      expect((await register('remote.json')).errors, isEmpty);
    });
  });

  group('paths', () {
    test('.. after a symlink is resolved by the OS', () async {
      // temp/link -> temp/real/sub, so link/.. is temp/real, not temp.
      await Directory('${temp.path}/real/sub').create(recursive: true);
      await Link('${temp.path}/link').create('${temp.path}/real/sub');
      await write('real/manual.json', jsonEncode(manual));
      await write('manual.json', '{"tools": []}');
      final result = await register('link/../manual.json');
      expect(result.errors, isEmpty);
      expect(result.manual.tools, hasLength(2));
    }, testOn: 'posix');

    test('a file over maxFileBytes is not read', () async {
      await write('big.txt', 'x' * 101);
      final small = FileCommunicationProtocol(
        rootDir: temp.path,
        maxFileBytes: 100,
      );
      await write('ok.txt', 'x' * 100);
      expect(
        await small.callTool(
          client,
          'local.ok',
          const {},
          const FileCallTemplate(filePath: 'ok.txt'),
        ),
        'x' * 100,
      );
      await expectLater(
        small.callTool(
          client,
          'local.big',
          const {},
          const FileCallTemplate(filePath: 'big.txt'),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('larger than the limit of 100 bytes'),
          ),
        ),
      );
      await write('big.json', '{"tools": []}${' ' * 100}');
      final result = await small.registerManual(
        client,
        const FileCallTemplate(filePath: 'big.json'),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('larger than the limit'));
    });

    test('a file that is not UTF-8 fails the call', () async {
      await File('${temp.path}/bin').writeAsBytes([0xff, 0xfe, 0x00]);
      await expectLater(
        protocol.callTool(
          client,
          'local.bin',
          const {},
          const FileCallTemplate(filePath: 'bin'),
        ),
        throwsA(isA<UtcpException>()),
      );
    });
  });

  group('tool calls', () {
    test('return the content of the file', () async {
      await write('data/calc.txt', 'calc docs\nline 2');
      expect(
        await protocol.callTool(client, 'local.calculator', const {
          'ignored': true,
        }, const FileCallTemplate(filePath: 'data/calc.txt')),
        'calc docs\nline 2',
      );
    });

    test('a JSON file is returned as text', () async {
      await write('manual.json', jsonEncode(manual));
      final content = await protocol.callTool(
        client,
        'local.m',
        const {},
        const FileCallTemplate(filePath: 'manual.json'),
      );
      expect(jsonDecode('$content'), manual);
    });

    test('streaming yields the content once', () async {
      await write('a.txt', 'abc');
      expect(
        await protocol
            .callToolStreaming(
              client,
              'local.a',
              const {},
              const FileCallTemplate(filePath: 'a.txt'),
            )
            .toList(),
        ['abc'],
      );
    });

    test('a missing file fails the call', () async {
      await expectLater(
        protocol.callTool(
          client,
          'local.missing',
          const {},
          const FileCallTemplate(filePath: 'missing.txt'),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('missing.txt'),
          ),
        ),
      );
    });
  });
}
