/// [value] as Python's `str()` writes it, which the Python socket transports
/// use for a `text` request without a template: `None`, `True`, `False`,
/// `1.0`, `1e+16`, `['a', 1]`, `{'k': None}`.
///
/// Strings inside lists and maps are quoted and escaped as Python's `repr()`
/// does. Python's printability test needs the Unicode category table, so
/// only control characters, separators other than the space, common format
/// characters and lone surrogates are escaped; any other non-ASCII character
/// is kept as is.
String pythonStr(Object? value) => value is String ? value : _pythonRepr(value);

String _pythonRepr(Object? value) => switch (value) {
  null => 'None',
  true => 'True',
  false => 'False',
  final String s => _stringRepr(s),
  final int n => '$n',
  final double d => _floatRepr(d),
  final List<Object?> list => '[${list.map(_pythonRepr).join(', ')}]',
  final Map<Object?, Object?> map =>
    '{${[for (final MapEntry(:key, :value) in map.entries) '${_pythonRepr(key)}: ${_pythonRepr(value)}'].join(', ')}}',
  _ => '$value',
};

String _floatRepr(double d) {
  if (d.isNaN) return 'nan';
  if (d.isInfinite) return d > 0 ? 'inf' : '-inf';
  final sign = d.isNegative ? '-' : '';
  // The shortest round-trip digits, as Python's repr uses.
  final [mantissa, exponentText] = d.abs().toStringAsExponential().split('e');
  final digits = mantissa.replaceFirst('.', '');
  final exponent = int.parse(exponentText);
  if (exponent < -4 || exponent >= 16) {
    final fraction = digits.length > 1 ? '.${digits.substring(1)}' : '';
    final expSign = exponent < 0 ? '-' : '+';
    final expDigits = exponent.abs().toString().padLeft(2, '0');
    return '$sign${digits[0]}${fraction}e$expSign$expDigits';
  }
  if (exponent < 0) return '${sign}0.${'0' * (-exponent - 1)}$digits';
  final point = exponent + 1;
  if (digits.length <= point) return '$sign${digits.padRight(point, '0')}.0';
  return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
}

String _stringRepr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final rune in s.runes) {
    final char = String.fromCharCode(rune);
    out.write(switch (rune) {
      _ when char == quote || char == r'\' => '\\$char',
      0x09 => r'\t',
      0x0A => r'\n',
      0x0D => r'\r',
      _ when _isPrintable(rune) => char,
      <= 0xFF => '\\x${_hex(rune, 2)}',
      <= 0xFFFF => '\\u${_hex(rune, 4)}',
      _ => '\\U${_hex(rune, 8)}',
    });
  }
  out.write(quote);
  return out.toString();
}

bool _isPrintable(int rune) =>
    !(rune < 0x20 ||
        (rune >= 0x7F && rune <= 0xA0) ||
        rune == 0xAD ||
        rune == 0x1680 ||
        (rune >= 0x2000 && rune <= 0x200F) ||
        (rune >= 0x2028 && rune <= 0x202F) ||
        (rune >= 0x205F && rune <= 0x206F) ||
        rune == 0x3000 ||
        (rune >= 0xD800 && rune <= 0xDFFF) ||
        rune == 0xFEFF);

String _hex(int value, int width) =>
    value.toRadixString(16).padLeft(width, '0');
