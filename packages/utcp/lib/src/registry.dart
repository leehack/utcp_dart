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
  ]) : _factories = {...?builtIn},
       _parent = null;

  /// A registry whose own registrations take precedence over [parent]'s,
  /// and which falls back to [parent] for every other type, including types
  /// registered there later. Registering here never changes [parent].
  TypeRegistry.scoped(TypeRegistry<T> parent)
    : discriminator = parent.discriminator,
      _factories = {},
      _hints = const {},
      _parent = parent;

  final String discriminator;
  final Map<String, JsonFactory<T>> _factories;
  final Map<String, String> _hints;
  final TypeRegistry<T>? _parent;

  /// Registers [factory] for [type]. Returns `false`, leaving the existing
  /// parser in place, when [type] is already registered and [override] is
  /// not set.
  bool register(String type, JsonFactory<T> factory, {bool override = false}) {
    if (!override && contains(type)) return false;
    _factories[type] = factory;
    return true;
  }

  bool contains(String type) => _factoryFor(type) != null;

  Iterable<String> get types => {...?_parent?.types, ..._factories.keys};

  JsonFactory<T>? _factoryFor(String type) =>
      _factories[type] ?? _parent?._factoryFor(type);

  String? _hintFor(String type) => _hints[type] ?? _parent?._hintFor(type);

  T parse(JsonMap json) {
    final type = json.string(discriminator);
    final factory =
        _factoryFor(type) ??
        (throw FormatException(
          ["Unknown $discriminator '$type'.", ?_hintFor(type)].join(' '),
        ));
    return factory(json);
  }
}
