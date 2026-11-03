import '../json.dart';

/// A JSON Schema document (draft-07 subset used by UTCP) with typed access
/// to the keywords tools commonly use.
///
/// It is the decoded map itself, so it can be handed unchanged to an LLM API
/// as a tool's parameter schema.
extension type const JsonSchema._(JsonMap json) implements JsonMap {
  const JsonSchema(JsonMap json) : this._(json);

  static const empty = JsonSchema({});

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
