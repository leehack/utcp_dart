import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

void main() {
  group('JsonReader', () {
    const json = <String, Object?>{
      'name': 'x',
      'count': 3,
      'ratio': 2.0,
      'tags': ['a', 'b'],
      'headers': {'A': '1'},
      'items': [
        {'k': 1},
      ],
    };

    test('reads typed fields', () {
      expect(json.string('name'), 'x');
      expect(json.optInt('count'), 3);
      expect(json.optInt('ratio'), 2);
      expect(json.optStringList('tags'), ['a', 'b']);
      expect(json.optStringMap('headers'), {'A': '1'});
      expect(json.objectList('items').single, {'k': 1});
      expect(json.optString('missing'), isNull);
    });

    test('names the field when a type is wrong', () {
      expect(
        () => json.string('count'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            "Field 'count' must be a string, got number.",
          ),
        ),
      );
      expect(() => json.string('missing'), throwsFormatException);
      expect(
        () => <String, Object?>{
          'tags': ['a', 1],
        }.optStringList('tags'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('tags[1]'),
          ),
        ),
      );
      expect(
        () => <String, Object?>{'n': 1.5}.optInt('n'),
        throwsFormatException,
      );
    });
  });

  group('decodeYaml', () {
    test('parses documents into plain JSON values', () {
      expect(decodeYaml('a: [1, {b: x}]'), {
        'a': [
          1,
          {'b': 'x'},
        ],
      });
    });

    test('stops alias expansion bombs', () {
      final bomb = StringBuffer('a: &a [x, x, x, x, x, x, x, x, x, x]\n');
      for (var i = 1; i < 8; i++) {
        final prev = String.fromCharCode(96 + i);
        final next = String.fromCharCode(97 + i);
        bomb.writeln('$next: &$next [${List.filled(10, '*$prev').join(', ')}]');
      }
      expect(() => decodeYaml('$bomb'), throwsFormatException);
    });

    test('rejects collection keys, which could hide an alias bomb', () {
      final levels = StringBuffer('? [&a [x, x, x, x, x, x, x, x, x, x]');
      for (var i = 1; i < 8; i++) {
        final prev = String.fromCharCode(96 + i);
        final next = String.fromCharCode(97 + i);
        levels.write(', &$next [${List.filled(10, '*$prev').join(', ')}]');
      }
      expect(() => decodeYaml('$levels]\n: 1'), throwsFormatException);
    });

    test('rejects aliases used as keys before parsing', () {
      final ladder = StringBuffer('a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n');
      for (var i = 1; i < 12; i++) {
        final refs = List.filled(10, '*a${i - 1}').join(', ');
        ladder.writeln('a$i: &a$i [$refs]');
      }
      for (final key in [
        '*a11 : 1',
        '*a11\t: 1',
        'z: {*a11 : 1}',
        'z: {*a11}',
        'z: {y: 1, *a11 }',
        'z: [*a11 : 1]',
        '? *a11\n: 1',
        'z: |\n  text\n*a11 : 1',
        'z: {k: |\n  *a11 : 1}',
      ]) {
        expect(
          () => decodeYaml('$ladder$key\n'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('as mapping keys'),
            ),
          ),
          reason: key,
        );
      }
    });

    test('ignores key-like text in block scalars, quotes and comments', () {
      expect(
        decodeYaml('''
base: &b {x: 1}
use: *b
list: [*b, *b]
map: {a: *b, c: *b}
md: |
  **Note:** see [docs][1].
  *Deprecated* - why use this ?

  [1]: https://example.com/docs
items:
  - >-
    *a : not a key
  - k: |
      ? also text
    next: "*q : quoted"  # *c : comment
    note: '**Note**: the list
      *is* limited.'
'''),
        {
          'base': {'x': 1},
          'use': {'x': 1},
          'list': [
            {'x': 1},
            {'x': 1},
          ],
          'map': {
            'a': {'x': 1},
            'c': {'x': 1},
          },
          'md':
              '**Note:** see [docs][1].\n*Deprecated* - why use this ?\n\n'
              '[1]: https://example.com/docs\n',
          'items': [
            '*a : not a key',
            {
              'k': '? also text\n',
              'next': '*q : quoted',
              'note': '**Note**: the list *is* limited.',
            },
          ],
        },
      );
    });

    test('still checks lines after a block scalar ends', () {
      for (final doc in [
        'a: &a [1]\nl:\n- k: |\n    text\n  ? *a\n  : 1\n',
        'a: &a [1]\nl:\n- k: |\n  ? *a\n  : 1\n',
      ]) {
        expect(
          () => decodeYaml(doc),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('as mapping keys'),
            ),
          ),
          reason: doc,
        );
      }
    });

    test('accepts a long anchored scalar reused across a document', () {
      final doc = StringBuffer('errors:\n  e: &e "${'x' * 500}"\npaths:\n');
      for (var i = 0; i < 300; i++) {
        doc.writeln('  p$i: {a: *e, b: *e, c: *e}');
      }
      expect(decodeYaml('$doc'), containsPair('paths', hasLength(300)));
    });

    test('bounds a long scalar referenced by many aliases', () {
      final doc = StringBuffer('s: &s ${'x' * 100000}\nl:\n');
      for (var i = 0; i < 2000; i++) {
        doc.writeln('  - *s');
      }
      expect(() => decodeYaml('$doc'), throwsFormatException);
    });

    test('keeps aliases and bracketed text that are not collection keys', () {
      expect(
        decodeYaml('base: &b {x: 1}\nuse: *b\ndescription: "see [docs]: here"'),
        {
          'base': {'x': 1},
          'use': {'x': 1},
          'description': 'see [docs]: here',
        },
      );
    });

    test('accepts large documents without aliases', () {
      final doc = StringBuffer();
      for (var i = 0; i < 5000; i++) {
        doc.writeln('k$i: {name: value$i, list: [1, 2, 3]}');
      }
      expect(decodeYaml('$doc'), hasLength(5000));
    });
  });

  group('JsonSchema', () {
    test('exposes typed keywords and stays a plain map', () {
      const schema = JsonSchema({
        'type': 'object',
        'properties': {
          'city': {
            'type': ['string', 'null'],
            'enum': ['Seoul'],
          },
        },
        'required': ['city'],
      });
      expect(schema.types, ['object']);
      expect(schema.required, ['city']);
      expect(schema.properties['city']!.types, ['string', 'null']);
      expect(schema.properties['city']!.enumValues, ['Seoul']);
      expect(schema['type'], 'object');
      expect(JsonSchema.empty.types, isEmpty);
    });
  });

  group('TypeRegistry', () {
    test('parses by discriminator and keeps existing parsers', () {
      final registry = TypeRegistry<String>('kind', {
        'a': (json) => 'A:${json['v']}',
      });
      expect(registry.parse({'kind': 'a', 'v': 1}), 'A:1');
      expect(registry.register('a', (_) => 'other'), isFalse);
      expect(registry.register('a', (_) => 'other', override: true), isTrue);
      expect(registry.parse({'kind': 'a'}), 'other');
      expect(() => registry.parse({'kind': 'b'}), throwsFormatException);
      expect(() => registry.parse({}), throwsFormatException);
    });
  });
}
