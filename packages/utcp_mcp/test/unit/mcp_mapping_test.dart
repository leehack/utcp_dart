import 'package:test/test.dart';
import 'package:utcp_mcp/src/mcp_mapping.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

Object? text(String text) => toolResultValue({
  'content': [
    {'type': 'text', 'text': text},
  ],
});

void main() {
  group('toolResultValue', () {
    test('prefers structuredContent over content', () {
      expect(
        toolResultValue({
          'content': [
            {'type': 'text', 'text': '{"reply": "lossy"}'},
          ],
          'structuredContent': {'reply': 'exact'},
        }),
        {'reply': 'exact'},
      );
    });

    test('unwraps only the FastMCP wrapper around non-objects', () {
      Object? structured(Object value) =>
          toolResultValue({'content': <Object?>[], 'structuredContent': value});

      expect(structured({'result': 42}), 42);
      expect(
        structured({
          'result': ['a', 'b'],
        }),
        ['a', 'b'],
      );
      expect(structured({'result': null}), isNull);
      expect(structured({'result': 1, 'extra': 2}), {'result': 1, 'extra': 2});
      expect(structured({'answer': 42}), {'answer': 42});
      expect(
        structured({
          'result': {'nested': true},
        }),
        {
          'result': {'nested': true},
        },
      );
      expect(structured([1, 2]), [1, 2]);
    });

    test('accepts the legacy structured_output field', () {
      expect(
        toolResultValue({
          'structured_output': {'a': 1},
        }),
        {'a': 1},
      );
    });

    test('parses text as JSON, then as a number, else keeps it', () {
      expect(text('{"a": [1, 2]}'), {
        'a': [1, 2],
      });
      expect(text('[1, "x"]'), [1, 'x']);
      expect(text('7'), 7);
      expect(text('-2.5'), -2.5);
      expect(text(' 12 '), 12);
      expect(text('true'), true);
      expect(text('Hello, Ann!'), 'Hello, Ann!');
      expect(text('{not json'), '{not json');
      expect(text('NaN'), 'NaN');
      expect(text('Infinity'), 'Infinity');
      expect(text(''), '');
      expect(text('   '), '   ');
    });

    test('returns one item alone, several as a list, none as []', () {
      expect(
        toolResultValue({
          'content': [
            {'type': 'text', 'text': 'a'},
            {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
          ],
        }),
        [
          'a',
          {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
        ],
      );
      expect(toolResultValue({'content': <Object?>[]}), <Object?>[]);
    });

    test('returns isError results like any other', () {
      expect(
        toolResultValue({
          'content': [
            {'type': 'text', 'text': 'boom'},
          ],
          'isError': true,
        }),
        'boom',
      );
    });

    test('rejects malformed content', () {
      expect(
        () => toolResultValue({
          'content': ['text'],
        }),
        throwsFormatException,
      );
      expect(() => toolResultValue({'content': 'text'}), throwsFormatException);
    });
  });

  group('toolFromMcp', () {
    const template = McpCallTemplate(
      name: 'm',
      config: McpConfig(mcpServers: {}),
    );

    test('copies the schemas and names the tool manual.server.tool', () {
      final tool = toolFromMcp(
        {
          'name': 'read',
          'description': 'Reads',
          'inputSchema': {
            'type': 'object',
            'required': ['path'],
          },
          'outputSchema': {'type': 'object'},
        },
        'fs',
        template,
      );
      expect(tool.name, 'm.fs.read');
      expect(tool.description, 'Reads');
      expect(tool.inputs.required, ['path']);
      expect(tool.outputs.types, ['object']);
      expect(tool.toolCallTemplate, same(template));
    });

    test('omits the manual prefix for a template without a name', () {
      final tool = toolFromMcp(
        {'name': 'read'},
        'fs',
        const McpCallTemplate(config: McpConfig(mcpServers: {})),
      );
      expect(tool.name, 'fs.read');
      expect(tool.description, '');
    });

    test('maps a resource to a tool that reads it', () {
      final tool = toolFromMcpResource(
        {'name': 'config', 'uri': 'file:///config.json'},
        'fs',
        template,
      );
      expect(tool.name, 'm.fs.resource_config');
      expect(
        tool.description,
        'Read resource: config. URI: file:///config.json',
      );
      expect(tool.inputs.properties, isEmpty);
    });

    test('rejects a tool without a name', () {
      expect(() => toolFromMcp({}, 'fs', template), throwsFormatException);
    });
  });
}
