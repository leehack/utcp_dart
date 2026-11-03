import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
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
        'resource_config',
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

  group('resourceTools', () {
    JsonMap resource(String name, String uri) => {'name': name, 'uri': uri};
    Map<String, String> uris(
      List<JsonMap> resources, [
      Set<String> tools = const {},
    ]) => {
      for (final MapEntry(:key, :value) in resourceTools(
        resources,
        tools,
      ).entries)
        key: value.string('uri'),
    };

    test('names a resource resource_<name> when that is free', () {
      expect(uris([resource('config', 'file:///c')], {'read'}), {
        'resource_config': 'file:///c',
      });
    });

    test('numbers resources that share a name, in URI order', () {
      final resources = [
        resource('log', 'file:///b'),
        resource('log', 'file:///a'),
      ];
      expect(uris(resources), {
        'resource_log_1': 'file:///a',
        'resource_log_2': 'file:///b',
      });
      expect(uris(resources.reversed.toList()), uris(resources));
    });

    test('never takes the name of a tool', () {
      expect(uris([resource('x', 'file:///x')], {'resource_x'}), {
        'resource_x_1': 'file:///x',
      });
      expect(
        uris(
          [resource('x', 'file:///1'), resource('x', 'file:///2')],
          {'resource_x_1'},
        ),
        {'resource_x_2': 'file:///1', 'resource_x_3': 'file:///2'},
      );
    });

    test('skips a number another resource is named after', () {
      expect(
        uris([
          resource('a', 'file:///1'),
          resource('a', 'file:///2'),
          resource('a_1', 'file:///3'),
        ]),
        {
          'resource_a_1': 'file:///3',
          'resource_a_2': 'file:///1',
          'resource_a_3': 'file:///2',
        },
      );
    });

    test('counts a URI listed twice once', () {
      expect(uris([resource('c', 'file:///c'), resource('c', 'file:///c')]), {
        'resource_c': 'file:///c',
      });
    });

    test('rejects a resource without a name or URI', () {
      expect(
        () => resourceTools([
          {'uri': 'file:///c'},
        ], const {}),
        throwsFormatException,
      );
      expect(
        () => resourceTools([
          {'name': 'c'},
        ], const {}),
        throwsFormatException,
      );
    });
  });

  group('inlineSchemaRefs', () {
    test(r'inlines $defs references and drops the inlined $defs', () {
      expect(
        inlineSchemaRefs({
          'type': 'object',
          'properties': {
            'address': {r'$ref': r'#/$defs/Address'},
            'tags': {
              'type': 'array',
              'items': {r'$ref': '#/definitions/Tag'},
            },
          },
          r'$defs': {
            'Address': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
            },
          },
          'definitions': {
            'Tag': {'type': 'string'},
          },
        }),
        {
          'type': 'object',
          'properties': {
            'address': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
      );
    });

    test(r'merges keywords next to $ref over the target', () {
      expect(
        inlineSchemaRefs({
          'properties': {
            'when': {r'$ref': r'#/$defs/Date', 'description': 'Due date'},
          },
          r'$defs': {
            'Date': {'type': 'string', 'description': 'A date'},
          },
        }),
        {
          'properties': {
            'when': {'type': 'string', 'description': 'Due date'},
          },
        },
      );
    });

    test('follows nested references and decodes JSON pointers', () {
      expect(
        inlineSchemaRefs({
          'properties': {
            'a': {r'$ref': r'#/$defs/a~1b'},
            'b': {r'$ref': r'#/$defs/c%25d'},
          },
          r'$defs': {
            'a/b': {r'$ref': r'#/$defs/leaf'},
            'c%d': {r'$ref': r'#/$defs/leaf'},
            'leaf': {'type': 'integer'},
          },
        })['properties'],
        {
          'a': {'type': 'integer'},
          'b': {'type': 'integer'},
        },
      );
    });

    test(r'leaves a cycle as a $ref and keeps the $defs it points into', () {
      final schema = {
        r'$ref': r'#/$defs/Node',
        r'$defs': {
          'Node': {
            'type': 'object',
            'properties': {
              'children': {
                'type': 'array',
                'items': {r'$ref': r'#/$defs/Node'},
              },
              'root': {r'$ref': '#'},
            },
          },
        },
      };
      final inlined = inlineSchemaRefs(schema);
      expect(inlined['type'], 'object');
      expect(inlined['properties'], {
        'children': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/Node'},
        },
        'root': {r'$ref': '#'},
      });
      expect(inlined[r'$defs'], schema[r'$defs']);
    });

    test('leaves remote, anchor and unresolvable references in place', () {
      final schema = {
        'properties': {
          'remote': {r'$ref': 'https://example.com/schema.json'},
          'anchor': {r'$ref': '#node'},
          'missing': {r'$ref': r'#/$defs/Missing'},
          'bad': {r'$ref': r'#/$defs/%'},
        },
        r'$defs': {
          'Used': {'type': 'string'},
        },
      };
      expect(inlineSchemaRefs(schema), schema);
    });

    test(r'leaves data keywords and a property named $ref alone', () {
      final schema = {
        'properties': {
          r'$ref': {r'$ref': r'#/$defs/S'},
          'value': {
            'const': {r'$ref': r'#/$defs/S'},
            'default': {r'$ref': r'#/$defs/S'},
          },
        },
        r'$defs': {
          'S': {'type': 'string'},
        },
      };
      expect(inlineSchemaRefs(schema)['properties'], {
        r'$ref': {'type': 'string'},
        'value': {
          'const': {r'$ref': r'#/$defs/S'},
          'default': {r'$ref': r'#/$defs/S'},
        },
      });
    });

    test('inlines properties named like data keywords', () {
      final mode = {
        'type': 'string',
        'enum': ['a', 'b'],
      };
      expect(
        inlineSchemaRefs({
          'properties': {
            'default': {r'$ref': r'#/$defs/Mode'},
            'enum': {r'$ref': r'#/$defs/Mode'},
            'other': {r'$ref': r'#/$defs/Mode'},
          },
          'patternProperties': {
            '^const': {r'$ref': r'#/$defs/Mode'},
          },
          r'$defs': {'Mode': mode},
        }),
        {
          'properties': {'default': mode, 'enum': mode, 'other': mode},
          'patternProperties': {'^const': mode},
        },
      );
    });

    test('leaves a reference with a non-UTF-8 escape in place', () {
      final schema = {
        'properties': {
          'bad': {r'$ref': r'#/$defs/%FF'},
          'good': {r'$ref': r'#/$defs/S'},
        },
        r'$defs': {
          'S': {'type': 'string'},
        },
      };
      expect(inlineSchemaRefs(schema), {
        'properties': {
          'bad': {r'$ref': r'#/$defs/%FF'},
          'good': {'type': 'string'},
        },
        r'$defs': schema[r'$defs'],
      });
    });

    test('returns a schema that would expand exponentially unchanged', () {
      final defs = <String, Object?>{
        'd0': {'type': 'string'},
      };
      for (var i = 1; i <= 20; i++) {
        defs['d$i'] = {
          'type': 'array',
          'prefixItems': [
            {r'$ref': '#/\$defs/d${i - 1}'},
            {r'$ref': '#/\$defs/d${i - 1}'},
          ],
        };
      }
      final schema = {
        'properties': {
          'bomb': {r'$ref': r'#/$defs/d20'},
        },
        r'$defs': defs,
      };
      expect(inlineSchemaRefs(schema), same(schema));
    });

    test('returns a schema without references as is', () {
      final schema = {
        'type': 'object',
        r'$defs': {
          'Unused': {'type': 'string'},
        },
      };
      expect(inlineSchemaRefs(schema), schema);
      expect(inlineSchemaRefs(null), isEmpty);
    });

    test('toolFromMcp inlines the input and output schemas', () {
      final tool = toolFromMcp(
        {
          'name': 'create',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'item': {r'$ref': r'#/$defs/Item'},
            },
            r'$defs': {
              'Item': {'type': 'string'},
            },
          },
          'outputSchema': {
            r'$ref': r'#/$defs/Out',
            r'$defs': {
              'Out': {'type': 'object'},
            },
          },
        },
        'fs',
        const McpCallTemplate(config: McpConfig(mcpServers: {})),
      );
      expect(tool.inputs.json, {
        'type': 'object',
        'properties': {
          'item': {'type': 'string'},
        },
      });
      expect(tool.outputs.json, {'type': 'object'});
    });
  });
}
