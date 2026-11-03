import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp_socket/src/encodings.dart';

void main() {
  String decode(String name, List<int> bytes) =>
      responseDecoder(name)!(Uint8List.fromList(bytes));

  test('Python spellings resolve, ignoring case, dashes and underscores', () {
    for (final name in [
      'utf-8',
      'UTF8',
      'utf_8',
      'ascii',
      'US-ASCII',
      'latin-1',
      'latin_1',
      'ISO-8859-1',
      'iso8859_1',
      'l1',
      'utf-16',
      'UTF-16-LE',
      'utf_16_be',
      'cp1252',
      'windows-1252',
    ]) {
      expect(responseDecoder(name), isNotNull, reason: name);
    }
    for (final name in ['ebcdic', 'utf-7', 'shift_jis', '']) {
      expect(responseDecoder(name), isNull, reason: name);
    }
  });

  test('latin-1 decodes every byte', () {
    expect(decode('latin-1', [0x63, 0x61, 0x66, 0xE9]), 'café');
  });

  test('cp1252 maps 0x80-0x9F and rejects its undefined bytes', () {
    expect(decode('cp1252', [0x80, 0x93, 0x61, 0x94]), '€“a”');
    expect(() => decode('cp1252', [0x81]), throwsFormatException);
  });

  group('utf-16', () {
    final hi = '😀a';

    test('little- and big-endian, with and without a BOM', () {
      final le = <int>[0x3D, 0xD8, 0x00, 0xDE, 0x61, 0x00];
      final be = <int>[0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x61];
      expect(decode('utf-16-le', le), hi);
      expect(decode('utf-16-be', be), hi);
      expect(decode('utf-16', [0xFF, 0xFE, ...le]), hi);
      expect(decode('utf-16', [0xFE, 0xFF, ...be]), hi);
      expect(decode('utf-16', le), hi);
    });

    test('odd lengths and unpaired surrogates are invalid', () {
      expect(() => decode('utf-16-le', [0x61]), throwsFormatException);
      expect(
        () => decode('utf-16-le', [0x3D, 0xD8, 0x61, 0x00]),
        throwsFormatException,
      );
      expect(() => decode('utf-16-le', [0x00, 0xDE]), throwsFormatException);
    });
  });

  test('invalid UTF-8 and non-ASCII bytes are invalid', () {
    expect(() => decode('utf-8', [0xFF]), throwsFormatException);
    expect(() => decode('ascii', [0xE9]), throwsFormatException);
    expect(decode('utf-8', utf8.encode('ü')), 'ü');
  });
}
