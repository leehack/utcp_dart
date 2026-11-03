import 'dart:typed_data';

import '../json.dart';
import 'tool_post_processor.dart';

/// Removes object keys from tool results, at any depth, as the Python
/// reference does.
///
/// [excludeKeys] drops the named keys. [onlyIncludeKeys] keeps the named
/// keys (an object under a kept key is filtered too) plus any other key whose
/// filtered value is a non-empty object or array; inside arrays it keeps only
/// non-empty objects and arrays. When both are set, [excludeKeys] runs first.
/// Either filter drops objects and arrays left empty inside an array.
class FilterDictPostProcessor extends ScopedToolPostProcessor {
  const FilterDictPostProcessor({
    this.excludeKeys,
    this.onlyIncludeKeys,
    super.excludeTools,
    super.onlyIncludeTools,
    super.excludeManuals,
    super.onlyIncludeManuals,
  });

  factory FilterDictPostProcessor.fromJson(JsonMap json) =>
      FilterDictPostProcessor(
        excludeKeys: json.optStringList('exclude_keys'),
        onlyIncludeKeys: json.optStringList('only_include_keys'),
        excludeTools: json.optStringList('exclude_tools'),
        onlyIncludeTools: json.optStringList('only_include_tools'),
        excludeManuals: json.optStringList('exclude_manuals'),
        onlyIncludeManuals: json.optStringList('only_include_manuals'),
      );

  static const type = 'filter_dict';

  final List<String>? excludeKeys;
  final List<String>? onlyIncludeKeys;

  @override
  String get toolPostProcessorType => type;

  @override
  Object? process(Object? result) {
    final exclude = excludeKeys;
    final onlyInclude = onlyIncludeKeys;
    if (exclude != null && exclude.isNotEmpty) {
      result = _exclude(result, exclude.toSet());
    }
    if (onlyInclude != null && onlyInclude.isNotEmpty) {
      result = _onlyInclude(result, onlyInclude.toSet());
    }
    return result;
  }

  static Object? _exclude(Object? value, Set<String> keys) => switch (value) {
    TypedData() => value,
    Map<Object?, Object?>() => <String, Object?>{
      for (final MapEntry(:key, :value) in value.entries)
        if (!keys.contains('$key')) '$key': _exclude(value, keys),
    },
    List<Object?>() => [
      for (final item in value)
        if (_exclude(item, keys) case final kept when _size(kept) != 0) kept,
    ],
    _ => value,
  };

  static Object? _onlyInclude(Object? value, Set<String> keys) =>
      switch (value) {
        TypedData() => value,
        Map<Object?, Object?>() => <String, Object?>{
          for (final MapEntry(:key, :value) in value.entries)
            if (keys.contains('$key'))
              '$key': value is Map ? _onlyInclude(value, keys) : value
            else if (_onlyInclude(value, keys) case final kept
                when (_size(kept) ?? 0) > 0)
              '$key': kept,
        },
        List<Object?>() => [
          for (final item in value)
            if (_onlyInclude(item, keys) case final kept
                when (_size(kept) ?? 0) > 0)
              kept,
        ],
        _ => value,
      };

  /// The length of an object or array; `null` for anything else, bytes
  /// included.
  static int? _size(Object? value) => switch (value) {
    TypedData() => null,
    Map<Object?, Object?>() => value.length,
    List<Object?>() => value.length,
    _ => null,
  };

  @override
  JsonMap fieldsToJson() => {
    'exclude_keys': ?excludeKeys,
    'only_include_keys': ?onlyIncludeKeys,
    ...scopeToJson(),
  };
}
