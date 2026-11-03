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

/// Parses a YAML document into plain JSON values.
///
/// YAML aliases are expanded, so a few hundred bytes of nested aliases can
/// describe billions of nodes. Expansion stops with a [FormatException] once
/// it produces more than ten nodes, or a hundred string characters, per
/// input character; documents written without such aliases stay far below.
Object? decodeYaml(String text) {
  _rejectNonScalarKeys(text);
  var nodes = text.length * 10 + 10000;
  var chars = text.length * 100 + 1000000;
  void spend(int nodeCost, int charCost) {
    nodes -= nodeCost;
    chars -= charCost;
    if (nodes < 0 || chars < 0) {
      throw const FormatException(
        'YAML document expands too far (alias expansion).',
      );
    }
  }

  Object? convert(Object? node) {
    // Aliased strings are shared in memory but copied by every encoder
    // downstream, so their length is bounded too.
    spend(1, node is String ? node.length : 0);
    return switch (node) {
      YamlMap() => <String, Object?>{
        for (final e in node.entries) _yamlKey(e.key, spend): convert(e.value),
      },
      YamlList() => <Object?>[for (final e in node) convert(e)],
      _ => node,
    };
  }

  return convert(loadYaml(text));
}

/// package:yaml deep-hashes collection keys while parsing, which expands
/// aliases inside them before any budget can apply. JSON keys are strings,
/// so a document that may use an alias or a collection as a key is refused
/// before parsing.
///
/// The check reads the document's structure, skipping block scalars, quoted
/// scalars and comments. When unsure it refuses: it may reject an unusual
/// document, but never lets such a key through.
void _rejectNonScalarKeys(String text) {
  final structure = _yamlStructure(text);
  if (_aliasKey.hasMatch(structure) ||
      _hasFlowAliasKey(structure) ||
      (_mayHaveAlias.hasMatch(structure) &&
          _mayHaveCollectionKey.hasMatch(structure))) {
    throw const FormatException(
      'YAML documents that use aliases or collections as mapping keys are '
      'not supported.',
    );
  }
}

/// [text] without block scalar lines, and with quoted scalars and comments
/// blanked.
String _yamlStructure(String text) {
  final out = StringBuffer();
  int? blockParent;
  int? blockIndent;
  var flowDepth = 0;
  for (final raw in text.split('\n')) {
    if (blockParent != null) {
      if (raw.trim().isEmpty) continue;
      final indent = _leadingSpaces.firstMatch(raw)!.end;
      blockIndent ??= indent > blockParent ? indent : null;
      if (blockIndent != null && indent >= blockIndent) continue;
      blockParent = blockIndent = null;
    }
    final line = raw.replaceAll(_quotedOrComment, '""');
    out.writeln(line);
    final depthBefore = flowDepth;
    for (final c in line.codeUnits) {
      if (c == _openBracket || c == _openBrace) flowDepth++;
      if ((c == _closeBracket || c == _closeBrace) && flowDepth > 0) {
        flowDepth--;
      }
    }
    // Block scalars cannot appear inside flow collections.
    if (depthBefore != 0 || flowDepth != 0) continue;
    final opener = _blockScalarStart.firstMatch(line);
    if (opener == null) continue;
    final nodeStart = _nodeStart.firstMatch(line)!.group(0)!;
    // Content is indented past the key after `key: |`; past the last `-` or
    // `?` marker after `- |`; and past at least the line's own indentation
    // minus one when `|` sits alone below its key.
    blockParent = opener.group(1) != null
        ? nodeStart.length
        : nodeStart.trimRight().length - 1;
  }
  return out.toString();
}

/// Whether an alias stands alone as an entry of a flow mapping (`{*a}`,
/// `{x: 1, *a}`), which makes it a key.
bool _hasFlowAliasKey(String structure) {
  final flow = <int>[];
  var previous = _comma;
  for (var i = 0; i < structure.length; i++) {
    final c = structure.codeUnitAt(i);
    if (c == _openBracket || c == _openBrace) {
      flow.add(c);
    } else if ((c == _closeBracket || c == _closeBrace) && flow.isNotEmpty) {
      flow.removeLast();
    } else if (c == _star &&
        flow.lastOrNull == _openBrace &&
        (previous == _openBrace || previous == _comma)) {
      var end = i + 1;
      while (end < structure.length &&
          !_aliasEnd.contains(structure.codeUnitAt(end))) {
        end++;
      }
      final next = _nextNonSpace(structure, end);
      if (next == null || next == _comma || next == _closeBrace) return true;
    }
    if (!_whitespace.contains(c)) previous = c;
  }
  return false;
}

int? _nextNonSpace(String s, int from) {
  for (var i = from; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (!_whitespace.contains(c)) return c;
  }
  return null;
}

const _openBracket = 0x5B, _closeBracket = 0x5D;
const _openBrace = 0x7B, _closeBrace = 0x7D;
const _comma = 0x2C, _star = 0x2A;
const _whitespace = {0x20, 0x09, 0x0A, 0x0D};
const _aliasEnd = {
  ..._whitespace,
  _comma,
  _openBracket,
  _closeBracket,
  _openBrace,
  _closeBrace,
};

final _leadingSpaces = RegExp('^[ \t]*');

/// Indentation plus the `-` and `?` markers that start a line's node.
final _nodeStart = RegExp('^[ \t]*(?:[-?][ \t]+)*');

/// A `|` or `>` block scalar indicator ending the line, after `key:` (group
/// 1) or at the start of a node, optionally after a tag or anchor.
final _blockScalarStart = RegExp(
  r'(?:(:[ \t]+)|^[ \t]*(?:[-?][ \t]+)*)(?:[!&]\S*[ \t]+)*[|>][1-9+-]{0,2}\s*$',
);

/// Quoted scalars where a scalar can start, and comments. A quote inside a
/// plain scalar (`it's`) is text, not a quote, so it is left alone.
final _quotedOrComment = RegExp(
  r'(?<=^[ \t]*(?:[-?][ \t]+)*|[\[{,][ \t]*|:[ \t]+)'
  r'''(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*')'''
  r'|(?<=^|[ \t])#.*',
);

final _mayHaveAlias = RegExp(
  r'(?:^|[\s,\[{:-])\*[^\s,\[\]{}]',
  multiLine: true,
);

/// An alias used as an implicit key, `*a : 1`. package:yaml reads `:` as part
/// of an alias name, so `*a: 1` is not a key and markdown such as
/// `**Note**: text` is left alone.
final _aliasKey = RegExp(
  r'(?:^|[\s,\[{?-])\*[^\s,\[\]{}]+[ \t]+:(?=[\s,\[\]{}]|$)',
  multiLine: true,
);

/// An explicit `?` key indicator, or a flow collection used as an implicit
/// key (`[a]: 1`, `{a: b}: 1`).
final _mayHaveCollectionKey = RegExp(
  r'(?:^|[\s,\[{])\?(?:\s|$)|[\]}]\s*:(?:\s|$)',
  multiLine: true,
);

/// JSON object keys are strings, so only scalar YAML keys are accepted; a
/// collection key could also hide an alias bomb behind `toString`.
String _yamlKey(Object? key, void Function(int, int) spend) {
  final value = key is YamlScalar ? key.value : key;
  if (value is Map || value is List) {
    throw const FormatException('YAML mapping keys must be scalars.');
  }
  final name = '$value';
  spend(1, name.length);
  return name;
}

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
