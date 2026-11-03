import 'json.dart';

/// Parses a JSON object into a [T].
typedef JsonFactory<T> = T Function(JsonMap json);

/// Parsers for the subtypes of [T], selected by the [discriminator] field
/// (for example `call_template_type`).
///
/// Plugins add their own subtypes with [register].
final class TypeRegistry<T> {
  /// [hints] tell the user how to register a known type that lives in
  /// another package, in the error for an unregistered type.
  TypeRegistry(
    this.discriminator, [
    Map<String, JsonFactory<T>>? builtIn,
    this._hints = const {},
  ]) : _factories = {...?builtIn};

  final String discriminator;
  final Map<String, JsonFactory<T>> _factories;
  final Map<String, String> _hints;

  /// Registers [factory] for [type]. Returns `false`, leaving the existing
  /// parser in place, when [type] is already registered and [override] is
  /// not set.
  bool register(String type, JsonFactory<T> factory, {bool override = false}) {
    if (!override && _factories.containsKey(type)) return false;
    _factories[type] = factory;
    return true;
  }

  bool contains(String type) => _factories.containsKey(type);

  Iterable<String> get types => _factories.keys;

  T parse(JsonMap json) {
    final type = json.string(discriminator);
    final factory =
        _factories[type] ??
        (throw FormatException(
          ["Unknown $discriminator '$type'.", ?_hints[type]].join(' '),
        ));
    return factory(json);
  }
}
