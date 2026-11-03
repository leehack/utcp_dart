import 'dart:async';

import 'env/environment.dart';
import 'exceptions.dart';
import 'json.dart';
import 'registry.dart';

/// A source of variable values consulted after `UtcpClientConfig.variables`
/// and before the process environment.
///
/// Loaders that can be configured from JSON (`load_variables_from`) register
/// a parser for their `variable_loader_type` in [VariableLoader.registry].
abstract class VariableLoader {
  static final registry =
      TypeRegistry<VariableLoader>('variable_loader_type', null, const {
        'dotenv':
            'Add package utcp_file and construct FileCommunicationProtocol or '
            'call DotEnvVariableLoader.register() first.',
      });

  /// The value of [key], or `null` when this loader does not define it.
  FutureOr<String?> get(String key);
}

/// Resolves `${VAR}` and `$VAR` placeholders in call templates.
///
/// Inside a manual, variables are namespaced: `${API_KEY}` in manual
/// `my_api` resolves the key `my__api_API_KEY` (underscores in the manual
/// name are doubled, then joined with `_`). This matches the Python and
/// TypeScript SDKs so the same configuration works across them.
class VariableSubstitutor {
  const VariableSubstitutor({
    this.variables = const {},
    this.loaders = const [],
    this.environment,
  });

  final Map<String, String> variables;
  final List<VariableLoader> loaders;

  /// Overrides the process environment; mainly for tests and platforms
  /// without one.
  final Map<String, String>? environment;

  static final _placeholder = RegExp(r'\$\{(\w+)\}|\$(\w+)');
  static final _validNamespace = RegExp(r'^\w+$');

  static String namespacedKey(String key, String? namespace) =>
      namespace == null ? key : '${namespace.replaceAll('_', '__')}_$key';

  Future<String> _lookup(String key) async {
    final fromConfig = variables[key];
    if (fromConfig != null) return fromConfig;
    for (final loader in loaders) {
      final value = await loader.get(key);
      if (value != null && value.isNotEmpty) return value;
    }
    final fromEnv = (environment ?? platformEnvironment())[key];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    throw UtcpVariableNotFoundException(key);
  }

  /// Returns a deep copy of [value] with every placeholder in its strings
  /// replaced. Strings containing `$ref` are left untouched so JSON Schema
  /// references survive.
  Future<Object?> substitute(Object? value, {String? namespace}) async {
    _checkNamespace(namespace);
    return _substitute(value, namespace);
  }

  Future<JsonMap> substituteMap(JsonMap value, {String? namespace}) async =>
      asJsonMap(await substitute(value, namespace: namespace), 'Substituted');

  Future<Map<String, String>> substituteStrings(
    Map<String, String> value,
  ) async => {
    for (final MapEntry(:key, :value) in value.entries)
      key: '${await substitute(value)}',
  };

  Future<Object?> _substitute(Object? value, String? namespace) async {
    switch (value) {
      case String():
        if (value.contains(r'$ref')) return value;
        final buffer = StringBuffer();
        var last = 0;
        for (final match in _placeholder.allMatches(value)) {
          buffer.write(value.substring(last, match.start));
          final name = match.group(1) ?? match.group(2)!;
          buffer.write(await _lookup(namespacedKey(name, namespace)));
          last = match.end;
        }
        buffer.write(value.substring(last));
        return buffer.toString();
      case List<Object?>():
        return <Object?>[
          for (final item in value) await _substitute(item, namespace),
        ];
      case Map<Object?, Object?>():
        return <String, Object?>{
          for (final entry in value.entries)
            entry.key.toString(): await _substitute(entry.value, namespace),
        };
      default:
        return value;
    }
  }

  /// Lists the (namespaced) variable keys referenced anywhere in [value].
  List<String> findRequiredVariables(Object? value, {String? namespace}) {
    _checkNamespace(namespace);
    final found = <String>{};
    void visit(Object? node) {
      switch (node) {
        case String():
          if (node.contains(r'$ref')) return;
          for (final match in _placeholder.allMatches(node)) {
            found.add(
              namespacedKey(match.group(1) ?? match.group(2)!, namespace),
            );
          }
        case List<Object?>():
          node.forEach(visit);
        case Map<Object?, Object?>():
          node.values.forEach(visit);
      }
    }

    visit(value);
    return found.toList();
  }

  static void _checkNamespace(String? namespace) {
    if (namespace != null && !_validNamespace.hasMatch(namespace)) {
      throw ArgumentError.value(
        namespace,
        'namespace',
        'Only alphanumeric characters and underscores are allowed',
      );
    }
  }
}
