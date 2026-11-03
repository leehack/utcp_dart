import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../support/fake_protocol.dart';
import '../../support/streaming.dart';

void main() {
  late UtcpClient caller;
  setUpAll(() async => caller = await bareClient());
  tearDownAll(() => caller.close());

  Object? run(
    JsonMap config,
    Object? result, {
    String tool = 'weather.get',
    String manual = 'weather',
  }) => ToolPostProcessor.fromJson(
    config,
  ).postProcess(caller, fakeTool(tool), FakeCallTemplate(name: manual), result);

  group('filter_dict', () {
    JsonMap filter(JsonMap fields) => {
      'tool_post_processor_type': 'filter_dict',
      ...fields,
    };

    final nested = {
      'id': 1,
      'secret': 's',
      'user': {'name': 'a', 'secret': 't'},
      'items': [
        {'secret': 'x'},
        {'name': 'b', 'secret': 'y'},
        <Object?>[],
        'text',
        7,
      ],
    };

    test('exclude_keys drops keys at any depth and empty array items', () {
      expect(
        run(
          filter({
            'exclude_keys': ['secret'],
          }),
          nested,
        ),
        {
          'id': 1,
          'user': {'name': 'a'},
          'items': [
            {'name': 'b'},
            'text',
            7,
          ],
        },
      );
    });

    test('only_include_keys keeps named keys and non-empty containers', () {
      expect(
        run(
          filter({
            'only_include_keys': ['name'],
          }),
          nested,
        ),
        {
          'user': {'name': 'a'},
          'items': [
            {'name': 'b'},
          ],
        },
      );
    });

    test('a kept key keeps an array whole but filters an object', () {
      expect(
        run(
          filter({
            'only_include_keys': ['items', 'user'],
          }),
          nested,
        ),
        {'user': <String, Object?>{}, 'items': nested['items']},
      );
    });

    test('only_include_keys drops scalars inside arrays', () {
      expect(
        run(
          filter({
            'only_include_keys': ['a'],
          }),
          [
            1,
            'x',
            {'a': 1, 'b': 2},
          ],
        ),
        [
          {'a': 1},
        ],
      );
    });

    test('exclude_keys runs before only_include_keys', () {
      expect(
        run(
          filter({
            'exclude_keys': ['name'],
            'only_include_keys': ['name', 'id'],
          }),
          nested,
        ),
        {'id': 1},
      );
    });

    test('scalars, bytes and unset or empty key lists pass through', () {
      final bytes = Uint8List.fromList([1, 2]);
      expect(
        run(
          filter({
            'exclude_keys': ['a'],
          }),
          'text',
        ),
        'text',
      );
      expect(
        run(
          filter({
            'only_include_keys': ['a'],
          }),
          bytes,
        ),
        same(bytes),
      );
      expect(run(filter({}), nested), same(nested));
      expect(run(filter({'only_include_keys': []}), nested), same(nested));
    });
  });

  group('limit_strings', () {
    test('truncates nested strings by code point, leaving keys alone', () {
      expect(
        run(
          {'tool_post_processor_type': 'limit_strings', 'limit': 3},
          {
            'long_key': 'abcdef',
            'list': ['😀😀😀😀', 'ab', 12, null, true],
            'nested': {'x': 'xyzw'},
          },
        ),
        {
          'long_key': 'abc',
          'list': ['😀😀😀', 'ab', 12, null, true],
          'nested': {'x': 'xyz'},
        },
      );
    });

    test('defaults to 10000 and leaves bytes alone', () {
      final processor =
          ToolPostProcessor.fromJson({
                'tool_post_processor_type': 'limit_strings',
              })
              as LimitStringsPostProcessor;
      expect(processor.limit, 10000);
      final bytes = Uint8List(20000);
      expect(
        run({'tool_post_processor_type': 'limit_strings', 'limit': 1}, bytes),
        same(bytes),
      );
    });

    test('a non-positive limit is rejected', () {
      for (final limit in [0, -1, 'ten', 1.5]) {
        expect(
          () => ToolPostProcessor.fromJson({
            'tool_post_processor_type': 'limit_strings',
            'limit': limit,
          }),
          throwsFormatException,
        );
      }
    });
  });

  group('tool and manual scope', () {
    JsonMap limit(JsonMap scope) => {
      'tool_post_processor_type': 'limit_strings',
      'limit': 1,
      ...scope,
    };

    test('exclude and only_include filters decide what is processed', () {
      final cases = <(JsonMap, String, String, bool)>[
        ({}, 'weather.get', 'weather', true),
        (
          {
            'exclude_tools': ['weather.get'],
          },
          'weather.get',
          'weather',
          false,
        ),
        (
          {
            'exclude_tools': ['weather.other'],
          },
          'weather.get',
          'weather',
          true,
        ),
        (
          {
            'only_include_tools': ['weather.get'],
          },
          'weather.get',
          'weather',
          true,
        ),
        (
          {
            'only_include_tools': ['weather.x'],
          },
          'weather.get',
          'weather',
          false,
        ),
        (
          {
            'exclude_manuals': ['weather'],
          },
          'weather.get',
          'weather',
          false,
        ),
        (
          {
            'only_include_manuals': ['news'],
          },
          'weather.get',
          'weather',
          false,
        ),
        (
          {
            'only_include_manuals': ['weather'],
          },
          'weather.get',
          'weather',
          true,
        ),
        ({'only_include_tools': []}, 'weather.get', 'weather', true),
        (
          {
            'only_include_tools': ['weather.get'],
            'exclude_tools': ['weather.get'],
          },
          'weather.get',
          'weather',
          false,
        ),
      ];
      for (final (scope, tool, manual, processed) in cases) {
        expect(
          run(limit(scope), 'abc', tool: tool, manual: manual),
          processed ? 'a' : 'abc',
          reason: '$scope',
        );
      }
    });

    test('filter_dict honours the same scope', () {
      expect(
        run(
          {
            'tool_post_processor_type': 'filter_dict',
            'exclude_keys': ['a'],
            'exclude_manuals': ['weather'],
          },
          {'a': 1},
        ),
        {'a': 1},
      );
    });
  });

  group('registry', () {
    test('configs round-trip through toJson', () {
      for (final config in [
        {
          'tool_post_processor_type': 'filter_dict',
          'exclude_keys': ['a'],
          'only_include_keys': ['b'],
          'exclude_tools': ['t'],
          'only_include_tools': ['u'],
          'exclude_manuals': ['m'],
          'only_include_manuals': ['n'],
        },
        {
          'tool_post_processor_type': 'limit_strings',
          'limit': 5,
          'only_include_manuals': ['n'],
        },
      ]) {
        expect(ToolPostProcessor.fromJson(config).toJson(), config);
      }
    });

    test('unknown types and malformed fields are rejected', () {
      expect(
        () => ToolPostProcessor.fromJson({'tool_post_processor_type': 'x'}),
        throwsFormatException,
      );
      expect(
        () => ToolPostProcessor.fromJson({
          'tool_post_processor_type': 'filter_dict',
          'exclude_keys': 'secret',
        }),
        throwsFormatException,
      );
    });
  });
}
