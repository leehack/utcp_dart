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
