/// Reads object literals out of JSON, JavaScript, TypeScript and Python
/// source, so documents written in an SDK's tests count like the spec's JSON.
library;

/// The syntax a source text is written in.
enum Syntax {
  /// JSON, JSON with comments, JavaScript and TypeScript.
  js,

  /// Python.
  python,
}

/// An object literal found in source text.
class Literal {
  const Literal._(this.value, this.line, this._end);

  /// The decoded JSON value.
  final Map<String, Object?> value;

  /// The 1-based line of the opening brace.
  final int line;

  /// The index of the token after the closing brace.
  final int _end;
}

enum _Kind { punct, string, number, identifier, expression }

class _Token {
  _Token(
    this.kind,
    this.text,
    this.start,
    this.end,
    this.line, {
    this.string,
    this.number,
  });

  final _Kind kind;
  final String text;
  final int start;
  final int end;
  final int line;
  final String? string;
  final num? number;

  bool isPunct(String p) => kind == _Kind.punct && text == p;
}

/// Thrown internally when a literal holds something JSON cannot express.
class _NotJson implements Exception {
  const _NotJson();
}

/// A tokenized source text whose object literals can be decoded.
///
/// Code that evaluates to a string (an interpolated string, a
/// concatenation) becomes the string `<source text>`, so the document keeps
/// its shape. TypeScript `as T` casts are dropped, and so are keys whose
/// value is `undefined`, as `JSON.stringify` does. Other code (a variable, a
/// call), a spread, a computed key or a method makes the whole literal
/// unreadable.
class LiteralSource {
  /// Tokenizes [text]. Line numbers start at [firstLine].
  LiteralSource(this.text, this.syntax, {int firstLine = 1})
    : _tokens = _tokenize(text, syntax, firstLine);

  /// The source text.
  final String text;

  /// The syntax [text] is written in.
  final Syntax syntax;

  final List<_Token> _tokens;

  /// Every object literal [accept] keeps, outermost first; the literals
  /// inside a kept one are not visited.
  Iterable<Literal> objects(bool Function(Map<String, Object?>) accept) sync* {
    var i = 0;
    while (i < _tokens.length) {
      if (_tokens[i].isPunct('{')) {
        final literal = _tryObject(i);
        if (literal != null && accept(literal.value)) {
          yield literal;
          i = literal._end;
          continue;
        }
      }
      i++;
    }
  }

  Literal? _tryObject(int i) {
    try {
      final (value, end) = _object(i);
      return Literal._(value, _tokens[i].line, end);
    } on _NotJson {
      return null;
    } on RangeError {
      return null;
    }
  }

  static final _undefined = Object();

  (Map<String, Object?>, int) _object(int i) {
    final result = <String, Object?>{};
    i++;
    while (true) {
      final token = _tokens[i];
      if (token.isPunct('}')) return (result, i + 1);
      if (token.isPunct('...') && _elision(i)) {
        i = _skipSeparator(i + 1, '}');
        continue;
      }
      final String key;
      switch (token.kind) {
        case _Kind.string:
          key = token.string!;
        case _Kind.number:
          key = token.text;
        case _Kind.identifier:
          key = token.text;
        default:
          throw const _NotJson();
      }
      i++;
      final Object? value;
      if (_tokens[i].isPunct(':')) {
        (value, i) = _value(i + 1);
      } else {
        throw const _NotJson();
      }
      if (!identical(value, _undefined)) result[key] = value;
      i = _skipSeparator(i, '}');
    }
  }

  (List<Object?>, int) _array(int i) {
    final result = <Object?>[];
    i++;
    while (true) {
      if (_tokens[i].isPunct(']')) return (result, i + 1);
      if (_tokens[i].isPunct('...') && _elision(i)) {
        i = _skipSeparator(i + 1, ']');
        continue;
      }
      final Object? value;
      (value, i) = _value(i);
      result.add(identical(value, _undefined) ? null : value);
      i = _skipSeparator(i, ']');
    }
  }

  /// A `...` that stands for omitted entries rather than a spread.
  bool _elision(int i) {
    final next = _tokens[i + 1];
    return next.isPunct(',') || next.isPunct('}') || next.isPunct(']');
  }

  int _skipSeparator(int i, String close) {
    if (_tokens[i].isPunct(',')) return i + 1;
    if (_tokens[i].isPunct(close)) return i;
    throw const _NotJson();
  }

  (Object?, int) _value(int i) {
    final start = i;
    final token = _tokens[i];
    Object? value;
    if (token.isPunct('{')) {
      (value, i) = _object(i);
    } else if (token.isPunct('[')) {
      (value, i) = _array(i);
    } else {
      (value, i) = _scalar(i);
    }
    i = _skipCast(i);
    if (_atValueEnd(i)) return (value, i);
    return _expression(start);
  }

  (Object?, int) _scalar(int i) {
    final token = _tokens[i];
    switch (token.kind) {
      case _Kind.string:
        final text = StringBuffer(token.string ?? '');
        i++;
        while (_tokens[i].kind == _Kind.string && syntax == Syntax.python) {
          text.write(_tokens[i].string);
          i++;
        }
        return (text.toString(), i);
      case _Kind.number:
        return (token.number, i + 1);
      case _Kind.punct when token.text == '-' && _tokens[i + 1].number != null:
        return (-_tokens[i + 1].number!, i + 2);
      case _Kind.identifier:
        final keyword = switch (token.text) {
          'true' || 'True' => true,
          'false' || 'False' => false,
          'null' || 'None' => null,
          'undefined' => _undefined,
          _ => _expressionMarker,
        };
        if (!identical(keyword, _expressionMarker)) return (keyword, i + 1);
        return _expression(i);
      default:
        return _expression(i);
    }
  }

  static final _expressionMarker = Object();

  bool _atValueEnd(int i) {
    final token = _tokens[i];
    return token.isPunct(',') ||
        token.isPunct('}') ||
        token.isPunct(']') ||
        token.isPunct(')');
  }

  int _skipCast(int i) {
    var j = i;
    while (_tokens[j].isPunct('!')) {
      j++;
    }
    if (syntax == Syntax.js &&
        _tokens[j].kind == _Kind.identifier &&
        (_tokens[j].text == 'as' || _tokens[j].text == 'satisfies')) {
      return _skipToDelimiter(j + 1);
    }
    return j;
  }

  /// Code standing for a string becomes `<source>`. Code of any other or
  /// unknown type makes the literal unreadable: guessing would turn a
  /// variable holding an object into a string the parsers then reject.
  (String, int) _expression(int start) {
    final end = _skipToDelimiter(start);
    if (end == start || !_isString(start, end)) throw const _NotJson();
    final source = text
        .substring(_tokens[start].start, _tokens[end - 1].end)
        .replaceAll(RegExp(r'\s+'), ' ');
    return ('<$source>', end);
  }

  /// Whether the code in tokens [start] to [end] evaluates to a string: it
  /// has a string at the top level (an interpolation, a concatenation, a
  /// method call on a string) or converts with `String(…)` or `str(…)`.
  bool _isString(int start, int end) {
    final first = _tokens[start];
    if (first.kind == _Kind.identifier &&
        (first.text == 'String' || first.text == 'str') &&
        _tokens[start + 1].isPunct('(')) {
      return true;
    }
    var depth = 0;
    for (var i = start; i < end; i++) {
      final token = _tokens[i];
      if (token.isPunct('(') || token.isPunct('[') || token.isPunct('{')) {
        depth++;
      } else if (token.isPunct(')') ||
          token.isPunct(']') ||
          token.isPunct('}')) {
        depth--;
      } else if (depth == 0 &&
          (token.kind == _Kind.string || token.kind == _Kind.expression)) {
        return true;
      }
    }
    return false;
  }

  /// The index of the first `,` or closing bracket at nesting depth zero.
  int _skipToDelimiter(int i) {
    var depth = 0;
    while (true) {
      final token = _tokens[i];
      if (token.kind == _Kind.punct) {
        switch (token.text) {
          case '{' || '[' || '(':
            depth++;
          case '}' || ']' || ')':
            if (depth == 0) return i;
            depth--;
          case ',' when depth == 0:
            return i;
          case ';':
            throw const _NotJson();
        }
      }
      i++;
    }
  }
}

final _identifierStart = RegExp(r'[A-Za-z_$]');
final _identifierPart = RegExp(r'[A-Za-z0-9_$]');
final _number = RegExp(
  r'(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)',
);

List<_Token> _tokenize(String text, Syntax syntax, int firstLine) {
  final tokens = <_Token>[];
  var line = firstLine;
  var i = 0;
  void countLines(int from, int to) {
    for (var j = from; j < to; j++) {
      if (text.codeUnitAt(j) == 0x0A) line++;
    }
  }

  while (i < text.length) {
    final c = text[i];
    if (c == '\n') {
      line++;
      i++;
    } else if (c.trim().isEmpty) {
      i++;
    } else if (syntax == Syntax.js && text.startsWith('//', i) ||
        syntax == Syntax.python && c == '#') {
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end;
    } else if (syntax == Syntax.js && text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      final stop = end < 0 ? text.length : end + 2;
      countLines(i, stop);
      i = stop;
    } else if (c == '"' || c == "'" || c == '`') {
      final startLine = line;
      final (value, end, interpolated) = _string(text, i, syntax);
      countLines(i, end);
      tokens.add(
        interpolated
            ? _Token(
                _Kind.expression,
                text.substring(i, end),
                i,
                end,
                startLine,
              )
            : _Token(
                _Kind.string,
                text.substring(i, end),
                i,
                end,
                startLine,
                string: value,
              ),
      );
      i = end;
    } else if (_identifierStart.hasMatch(c)) {
      var end = i + 1;
      while (end < text.length && _identifierPart.hasMatch(text[end])) {
        end++;
      }
      final word = text.substring(i, end);
      final quote = end < text.length ? text[end] : '';
      if (syntax == Syntax.python &&
          (quote == '"' || quote == "'") &&
          RegExp(r'^[rRbBuUfF]{1,2}$').hasMatch(word)) {
        final startLine = line;
        final raw = word.toLowerCase().contains('r');
        final (value, stop, _) = _string(text, end, syntax, raw: raw);
        countLines(i, stop);
        final formatted = word.toLowerCase().contains('f');
        tokens.add(
          formatted
              ? _Token(
                  _Kind.expression,
                  text.substring(i, stop),
                  i,
                  stop,
                  startLine,
                )
              : _Token(
                  _Kind.string,
                  text.substring(i, stop),
                  i,
                  stop,
                  startLine,
                  string: value,
                ),
        );
        i = stop;
      } else {
        tokens.add(_Token(_Kind.identifier, word, i, end, line));
        i = end;
      }
    } else if (_numberAt(text, i) case final source?) {
      final value = source.startsWith(RegExp('0[xX]'))
          ? int.parse(source.substring(2), radix: 16)
          : num.parse(source);
      final end = i + source.length;
      tokens.add(_Token(_Kind.number, source, i, end, line, number: value));
      i = end;
    } else if (text.startsWith('...', i)) {
      tokens.add(_Token(_Kind.punct, '...', i, i + 3, line));
      i += 3;
    } else {
      tokens.add(_Token(_Kind.punct, c, i, i + 1, line));
      i++;
    }
  }
  tokens.add(_Token(_Kind.punct, '', text.length, text.length, line));
  return tokens;
}

String? _numberAt(String text, int i) {
  final source = _number.matchAsPrefix(text, i)?[0];
  if (source == null || source.isEmpty || source == '.') return null;
  return source;
}

(String, int, bool) _string(
  String text,
  int start,
  Syntax syntax, {
  bool raw = false,
}) {
  final quote = text[start];
  final triple = syntax == Syntax.python && text.startsWith(quote * 3, start);
  final delimiter = triple ? quote * 3 : quote;
  final buffer = StringBuffer();
  var interpolated = false;
  var i = start + delimiter.length;
  while (i < text.length) {
    if (text.startsWith(delimiter, i)) {
      return (buffer.toString(), i + delimiter.length, interpolated);
    }
    final c = text[i];
    if (c == '\n' && !triple && quote != '`') break;
    if (quote == '`' && text.startsWith(r'${', i)) interpolated = true;
    if (c == r'\' && i + 1 < text.length) {
      if (raw) {
        buffer.write(text.substring(i, i + 2));
        i += 2;
        continue;
      }
      final next = text[i + 1];
      switch (next) {
        case 'n':
          buffer.write('\n');
        case 't':
          buffer.write('\t');
        case 'r':
          buffer.write('\r');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '0':
          buffer.write('\x00');
        case '\n':
          break;
        case 'u' when i + 6 <= text.length:
          final code = int.tryParse(text.substring(i + 2, i + 6), radix: 16);
          if (code != null) {
            buffer.writeCharCode(code);
            i += 6;
            continue;
          }
          buffer.write(next);
        case 'x' when i + 4 <= text.length:
          final code = int.tryParse(text.substring(i + 2, i + 4), radix: 16);
          if (code != null) {
            buffer.writeCharCode(code);
            i += 4;
            continue;
          }
          buffer.write(next);
        default:
          buffer.write(next);
      }
      i += 2;
      continue;
    }
    buffer.write(c);
    i++;
  }
  // An unterminated string: treat the rest of the line as code.
  final end = text.indexOf('\n', start);
  return ('', end < 0 ? text.length : end, true);
}
