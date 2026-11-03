import 'dart:typed_data';

import '../json.dart';
import 'tool_post_processor.dart';

/// Truncates every string in a tool result, at any depth, to [limit] code
/// points. Object keys are left alone.
class LimitStringsPostProcessor extends ScopedToolPostProcessor {
  const LimitStringsPostProcessor({
    this.limit = defaultLimit,
    super.excludeTools,
    super.onlyIncludeTools,
    super.excludeManuals,
    super.onlyIncludeManuals,
  });

  factory LimitStringsPostProcessor.fromJson(JsonMap json) {
    final limit = json.optInt('limit') ?? defaultLimit;
    if (limit <= 0) {
      throw FormatException("Field 'limit' must be positive, got $limit.");
    }
    return LimitStringsPostProcessor(
      limit: limit,
      excludeTools: json.optStringList('exclude_tools'),
      onlyIncludeTools: json.optStringList('only_include_tools'),
      excludeManuals: json.optStringList('exclude_manuals'),
      onlyIncludeManuals: json.optStringList('only_include_manuals'),
    );
  }

  static const type = 'limit_strings';

  static const defaultLimit = 10000;

  final int limit;

  @override
  String get toolPostProcessorType => type;

  @override
  Object? process(Object? result) => switch (result) {
    // Code points rather than UTF-16 units, so a surrogate pair is never
    // split; a string no longer than the limit in units cannot exceed it.
    String() when result.length > limit => String.fromCharCodes(
      result.runes.take(limit),
    ),
    Map<Object?, Object?>() => <String, Object?>{
      for (final MapEntry(:key, :value) in result.entries)
        '$key': process(value),
    },
    TypedData() => result,
    List<Object?>() => [for (final item in result) process(item)],
    _ => result,
  };

  @override
  JsonMap fieldsToJson() => {'limit': limit, ...scopeToJson()};
}
