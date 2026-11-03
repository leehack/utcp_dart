import 'unicode_names.dart';

const _simpleEscapes = {
  '\n': '', // Backslash-newline is a line continuation.
  r'\': r'\',
  "'": "'",
  '"': '"',
  'a': '\x07',
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t',
  'v': '\v',
};

final _octal = RegExp('[0-7]{1,3}');
final _hex = RegExp(r'^[0-9a-fA-F]+$');

/// Interprets the escapes Python's `unicode_escape` codec understands
/// (`\n`, `\x00`, `\0`, `é`, `\U0001F600`, `\N{NULL}`, ...), as the
/// Python TCP transport does for message delimiters. Unknown escapes are
/// kept as written. Throws a [FormatException] for a truncated escape.
///
/// `\N{name}` resolves names case-insensitively, as Python does, but only
/// for Basic Latin, Latin-1 Supplement, General Punctuation and U+FEFF
/// (with their aliases, such as `NUL` or `RS`); any other name is rejected.
/// The full Unicode name table would add over a megabyte for characters a
/// delimiter does not use.
String interpretEscapes(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final char = input[i];
    if (char != r'\') {
      out.write(char);
      i++;
      continue;
    }
    if (i + 1 >= input.length) {
      throw FormatException(r'Trailing \ in escape sequence.', input, i);
    }
    final next = input[i + 1];
    final simple = _simpleEscapes[next];
    if (simple != null) {
      out.write(simple);
      i += 2;
      continue;
    }
    final octal = _octal.matchAsPrefix(input, i + 1);
    if (octal != null) {
      out.writeCharCode(int.parse(octal.group(0)!, radix: 8));
      i = octal.end;
      continue;
    }
    final hexDigits = switch (next) {
      'x' => 2,
      'u' => 4,
      'U' => 8,
      _ => 0,
    };
    if (next == 'N') {
      final close = input.indexOf('}', i + 2);
      if (i + 2 >= input.length || input[i + 2] != '{' || close < 0) {
        throw FormatException(r'Malformed \N{...} escape.', input, i);
      }
      final name = input.substring(i + 3, close);
      final code =
          unicodeNames[name.toUpperCase()] ??
          (throw FormatException(
            'Unknown or unsupported character name in \\N{$name}.',
            input,
            i,
          ));
      out.writeCharCode(code);
      i = close + 1;
      continue;
    }
    if (hexDigits == 0) {
      out.write('\\$next');
      i += 2;
      continue;
    }
    final end = i + 2 + hexDigits;
    final digits = end <= input.length ? input.substring(i + 2, end) : '';
    final code = _hex.hasMatch(digits) ? int.parse(digits, radix: 16) : null;
    if (code == null || code > 0x10FFFF) {
      throw FormatException('Truncated or invalid \\$next escape.', input, i);
    }
    out.writeCharCode(code);
    i = end;
  }
  return out.toString();
}
