import 'dart:io';

import 'package:utcp/utcp.dart';

/// A [VariableLoader] that reads variables from a `.env` file
/// (`variable_loader_type: dotenv`).
///
/// The file is read on every lookup, so edits are picked up, and a missing
/// file defines nothing. See [parseDotEnv] for the format.
class DotEnvVariableLoader extends VariableLoader {
  /// A loader for the file at [envFilePath].
  DotEnvVariableLoader(this.envFilePath, {this.environment});

  /// Reads a loader from its JSON form (`env_file_path`).
  factory DotEnvVariableLoader.fromJson(JsonMap json) =>
      DotEnvVariableLoader(json.string('env_file_path'));

  /// The `variable_loader_type` of this loader.
  static const type = 'dotenv';

  /// Registers [DotEnvVariableLoader.fromJson] in [VariableLoader.registry],
  /// so `load_variables_from` entries of type `dotenv` parse in
  /// `UtcpClient.fromJson`. Safe to call more than once.
  static void register() =>
      VariableLoader.registry.register(type, DotEnvVariableLoader.fromJson);

  /// Absolute, or relative to the current directory.
  final String envFilePath;

  /// Variables `${NAME}` in the file falls back to; the process environment
  /// when null.
  final Map<String, String>? environment;

  @override
  Future<String?> get(String key) async {
    final file = File(envFilePath);
    if (!await file.exists()) return null;
    return parseDotEnv(
      await file.readAsString(),
      environment: environment ?? Platform.environment,
    )[key];
  }

  /// The JSON form read by [DotEnvVariableLoader.fromJson].
  @override
  JsonMap toJson() => {
    'variable_loader_type': type,
    'env_file_path': envFilePath,
  };
}

/// Parses `.env` text the way python-dotenv's `dotenv_values` does, which
/// the UTCP Python SDK uses for this loader:
///
/// - `KEY=value` lines; blank lines and `#` comment lines are skipped, and
///   a leading `export ` is ignored. Keys may be single-quoted.
/// - Unquoted values are trimmed and end at a `#` preceded by whitespace.
/// - `'...'` values unescape `\\` and `\'`; `"..."` values also unescape
///   `\"`, `\a`, `\b`, `\f`, `\n`, `\r`, `\t` and `\v`. Quoted values may
///   span lines.
/// - `${NAME}` and `${NAME:-default}` expand to an earlier value in the
///   file, else [environment], else the default or an empty string, in
///   every value, quoted or not.
/// - A key without `=` maps to null; a line that does not parse is skipped.
Map<String, String?> parseDotEnv(
  String source, {
  Map<String, String> environment = const {},
}) {
  final values = <String, String?>{};
  for (final (key, value) in _DotEnvReader(source).bindings()) {
    values[key] = value == null
        ? null
        : _expand(value, {...environment, ...values});
  }
  return values;
}

final _variable = RegExp(r'\$\{([^}:]*)(?::-([^}]*))?\}');

String _expand(String value, Map<String, String?> scope) =>
    value.replaceAllMapped(_variable, (match) {
      final name = match.group(1)!;
      return scope.containsKey(name) ? scope[name] ?? '' : match.group(2) ?? '';
    });

final _multilineWhitespace = RegExp(r'\s*');
final _whitespace = RegExp(r'[^\S\r\n]*');
final _export = RegExp(r'(?:export[^\S\r\n]+)?');
final _singleQuotedKey = RegExp(r"'([^']+)'");
final _unquotedKey = RegExp(r'([^=#\s]+)');
final _equalSign = RegExp(r'(=[^\S\r\n]*)');
final _singleQuotedValue = RegExp(r"'((?:\\.|[^'\\])*)'", dotAll: true);
final _doubleQuotedValue = RegExp(r'"((?:\\.|[^"\\])*)"', dotAll: true);
final _unquotedValue = RegExp(r'([^\r\n]*)');
final _inlineComment = RegExp(r'\s+#.*');
final _comment = RegExp(r'(?:[^\S\r\n]*#[^\r\n]*)?');
final _endOfLine = RegExp(r'[^\S\r\n]*(?:\r\n|\n|\r|$)');
final _restOfLine = RegExp(r'[^\r\n]*(?:\r|\n|\r\n)?');
final _singleQuoteEscape = RegExp(r"\\[\\']");
final _doubleQuoteEscape = RegExp(r'''\\[\\'"abfnrtv]''');

const _escapes = {
  'a': '\x07',
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t',
  'v': '\v',
};

final class _DotEnvReader {
  _DotEnvReader(String source)
    : _source = source.startsWith('﻿') ? source.substring(1) : source;

  final String _source;
  int _position = 0;

  bool get _hasNext => _position < _source.length;

  String get _peek => _hasNext ? _source[_position] : '';

  String? _read(RegExp pattern) {
    final match = pattern.matchAsPrefix(_source, _position);
    if (match == null) throw const _ParseError();
    _position = match.end;
    return match.groupCount > 0 ? match.group(1) : match.group(0);
  }

  Iterable<(String, String?)> bindings() sync* {
    while (_hasNext) {
      try {
        if (_binding() case (final String key, final value)) {
          yield (key, value);
        }
      } on _ParseError {
        _read(_restOfLine);
      }
    }
  }

  (String?, String?) _binding() {
    _read(_multilineWhitespace);
    if (!_hasNext) return (null, null);
    _read(_export);
    final key = switch (_peek) {
      '#' => null,
      "'" => _read(_singleQuotedKey),
      _ => _read(_unquotedKey),
    };
    _read(_whitespace);
    String? value;
    if (_peek == '=') {
      final equalSign = _read(_equalSign)!;
      // `KEY= # note` is empty with a comment; `KEY=#x` is the value `#x`.
      value = equalSign.length > 1 && _peek == '#' ? '' : _value();
    }
    _read(_comment);
    _read(_endOfLine);
    return (key, value);
  }

  String _value() => switch (_peek) {
    "'" => _unescape(_read(_singleQuotedValue)!, _singleQuoteEscape),
    '"' => _unescape(_read(_doubleQuotedValue)!, _doubleQuoteEscape),
    '' || '\n' || '\r' => '',
    _ => _read(_unquotedValue)!.replaceAll(_inlineComment, '').trimRight(),
  };

  static String _unescape(String value, RegExp escape) =>
      value.replaceAllMapped(escape, (match) {
        final char = match.group(0)![1];
        return _escapes[char] ?? char;
      });
}

final class _ParseError implements Exception {
  const _ParseError();
}
