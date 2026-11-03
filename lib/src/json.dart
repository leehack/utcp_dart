import 'package:yaml/yaml.dart';

typedef JsonMap = Map<String, dynamic>;

T? optionalField<T>(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! T) {
    throw FormatException("Field '$key' must be of type $T, got ${value.runtimeType}.");
  }
  return value;
}

T requiredField<T>(JsonMap json, String key) {
  final value = optionalField<T>(json, key);
  if (value == null) throw FormatException("Missing required field '$key'.");
  return value;
}

JsonMap asJsonMap(Object? value, String what) {
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  throw FormatException('$what must be a JSON object, got ${value.runtimeType}.');
}

JsonMap? optionalMap(JsonMap json, String key) {
  final value = json[key];
  return value == null ? null : asJsonMap(value, "Field '$key'");
}

List<String>? optionalStringList(JsonMap json, String key) {
  final value = optionalField<List>(json, key);
  return value?.map((e) {
    if (e is! String) throw FormatException("Field '$key' must contain only strings.");
    return e;
  }).toList();
}

Map<String, String>? optionalStringMap(JsonMap json, String key) {
  final value = optionalMap(json, key);
  return value?.map((k, v) {
    if (v is! String) throw FormatException("Field '$key.$k' must be a string.");
    return MapEntry(k, v);
  });
}

/// Converts parsed YAML nodes into plain JSON-compatible Dart values.
Object? yamlToJson(Object? node) => switch (node) {
  YamlMap() => {for (final e in node.entries) e.key.toString(): yamlToJson(e.value)},
  YamlList() => [for (final e in node) yamlToJson(e)],
  _ => node,
};
