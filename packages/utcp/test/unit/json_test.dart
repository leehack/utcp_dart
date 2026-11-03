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
