import '../json.dart';

/// A JSON Schema document (draft-07 subset used by UTCP) with typed access
/// to the keywords tools commonly use.
///
/// It is the decoded map itself, so it can be handed unchanged to an LLM API
/// as a tool's parameter schema.
extension type const JsonSchema._(JsonMap json) implements JsonMap {
  const JsonSchema(JsonMap json) : this._(json);

  /// Reads a schema from a UTCP document, dropping keywords whose value is
  /// null, here and in every nested schema. The Python SDK writes every
  /// keyword it models, unset ones as null (`"type": null`), which is not
  /// valid JSON Schema and which the TypeScript SDK rejects. `const` and
  /// `default` keep a null value, which is meaningful for them.
  factory JsonSchema.fromJson(JsonMap json) => JsonSchema(_withoutNulls(json));

  static const empty = JsonSchema({});

  static const _nullableKeywords = {'const', 'default'};

  static const _schemaMaps = {
    'properties',
    'patternProperties',
    r'$defs',
    'definitions',
  };

  static const _schemaLists = {'allOf', 'anyOf', 'oneOf', 'prefixItems'};

  static const _schemas = {
    'items',
    'additionalProperties',
    'additionalItems',
    'not',
    'if',
    'then',
    'else',
    'contains',
    'propertyNames',
  };

  static JsonMap _withoutNulls(JsonMap schema) => {
    for (final MapEntry(:key, :value) in schema.entries)
      if (value != null || _nullableKeywords.contains(key))
        key: switch (value) {
          final JsonMap map when _schemaMaps.contains(key) => {
            for (final MapEntry(:key, :value) in map.entries)
              key: value is JsonMap ? _withoutNulls(value) : value,
          },
          final List<Object?> list
              when _schemaLists.contains(key) || key == 'items' =>
            [
              for (final item in list)
                item is JsonMap ? _withoutNulls(item) : item,
            ],
          final JsonMap map when _schemas.contains(key) => _withoutNulls(map),
          _ => value,
        },
  };

  String? get title => json.optString('title');

  String? get description => json.optString('description');

  /// The `type` keyword, normalized to a list (`"string"` becomes
  /// `["string"]`). Empty when absent.
  List<String> get types => switch (json['type']) {
    null => const [],
    final String type => [type],
    _ => json.optStringList('type')!,
  };

  Map<String, JsonSchema> get properties => {
    for (final MapEntry(:key, :value)
        in (json.optObject('properties') ?? const {}).entries)
      key: JsonSchema(asJsonMap(value, "Schema property '$key'")),
  };

  List<String> get required => json.optStringList('required') ?? const [];

  /// The `items` schema when it is a single schema.
  JsonSchema? get items {
    final items = json['items'];
    return items is Map ? JsonSchema(asJsonMap(items, "Schema 'items'")) : null;
  }

  List<Object?>? get enumValues => json.optList('enum');

  Object? get defaultValue => json['default'];
}
