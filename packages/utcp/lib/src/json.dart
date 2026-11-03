import 'package:yaml/yaml.dart';

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// Converts a decoded JSON value into a [JsonMap], or throws a
/// [FormatException] naming [what].
JsonMap asJsonMap(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {for (final e in value.entries) e.key.toString(): e.value};
  }
  throw FormatException(
    '$what must be a JSON object, got ${_typeName(value)}.',
  );
}

/// Converts parsed YAML nodes into plain JSON values.
Object? yamlToJson(Object? node) => switch (node) {
  YamlMap() => <String, Object?>{
    for (final e in node.entries) e.key.toString(): yamlToJson(e.value),
  },
  YamlList() => <Object?>[for (final e in node) yamlToJson(e)],
  _ => node,
};

String _typeName(Object? value) => switch (value) {
  null => 'null',
  String() => 'string',
  bool() => 'boolean',
  num() => 'number',
  List<Object?>() => 'array',
  Map<Object?, Object?>() => 'object',
  _ => 'unsupported value',
};

/// Typed, path-aware field access for decoded JSON objects.
///
/// Every reader throws a [FormatException] naming the field when the value
/// has the wrong type, so parsers never cast.
extension JsonReader on JsonMap {
  T? _optional<T extends Object>(String key, String expected) {
    final value = this[key];
    if (value == null) return null;
    if (value is T) return value;
    throw FormatException(
      "Field '$key' must be $expected, got ${_typeName(value)}.",
    );
  }

  T _required<T extends Object>(String key, String expected) =>
      _optional<T>(key, expected) ??
      (throw FormatException("Missing required field '$key'."));

  String string(String key) => _required<String>(key, 'a string');

  String? optString(String key) => _optional<String>(key, 'a string');

  bool? optBool(String key) => _optional<bool>(key, 'a boolean');

  num? optNum(String key) => _optional<num>(key, 'a number');

  int? optInt(String key) {
    final value = optNum(key);
    if (value == null) return null;
    if (value is int) return value;
    if (value == value.truncate()) return value.toInt();
    throw FormatException("Field '$key' must be an integer, got $value.");
  }

  /// The non-negative integer at [key], read as milliseconds.
  Duration? optMilliseconds(String key) {
    final value = optInt(key);
    if (value == null) return null;
    if (value < 0) {
      throw FormatException("Field '$key' must not be negative, got $value.");
    }
    return Duration(milliseconds: value);
  }

  JsonMap object(String key) =>
      optObject(key) ??
      (throw FormatException("Missing required field '$key'."));

  JsonMap? optObject(String key) {
    final value = this[key];
    return value == null ? null : asJsonMap(value, "Field '$key'");
  }

  List<Object?>? optList(String key) =>
      _optional<List<Object?>>(key, 'an array');

  List<Object?> list(String key) => _required<List<Object?>>(key, 'an array');

  /// Each element of the array at [key] as a [JsonMap].
  List<JsonMap> objectList(String key) =>
      optObjectList(key) ??
      (throw FormatException("Missing required field '$key'."));

  List<JsonMap>? optObjectList(String key) {
    final value = optList(key);
    if (value == null) return null;
    return [
      for (final (i, item) in value.indexed)
        asJsonMap(item, "Field '$key[$i]'"),
    ];
  }

  List<String>? optStringList(String key) {
    final value = optList(key);
    if (value == null) return null;
    return [
      for (final (i, item) in value.indexed)
        item is String
            ? item
            : throw FormatException("Field '$key[$i]' must be a string."),
    ];
  }

  Map<String, String>? optStringMap(String key) {
    final value = optObject(key);
    if (value == null) return null;
    return {
      for (final MapEntry(key: name, value: item) in value.entries)
        name: item is String
            ? item
            : throw FormatException("Field '$key.$name' must be a string."),
    };
  }
}
