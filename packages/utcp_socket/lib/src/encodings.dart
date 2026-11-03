import 'dart:convert';
import 'dart:typed_data';

/// Decodes response bytes, throwing a [FormatException] for bytes that are
/// not valid in the encoding.
typedef ResponseDecoder = String Function(Uint8List bytes);

/// The decoder for a `response_byte_format`, or null when the encoding is
/// not supported.
///
/// Case and every character other than a letter or digit are ignored, a
/// superset of how Python's `codecs.lookup` normalizes names, so
/// `iso_646.irv:1991` finds `iso646irv1991`.
///
/// Supports the UTF-8, ASCII, Latin-1, UTF-16 and Windows-1252 families,
/// which covers the names used with the Python SDK in practice.
ResponseDecoder? responseDecoder(String name) =>
    _decoders[name.toLowerCase().replaceAll(_separators, '')];

final _separators = RegExp('[^a-z0-9]');

/// The error for a `response_byte_format` [responseDecoder] does not know.
String unsupportedResponseByteFormat(String name) =>
    "Unsupported response_byte_format '$name'. Supported: utf-8, ascii, "
    'latin-1, utf-16, utf-16-le, utf-16-be, cp1252.';

// Python's aliases, which include every name `Encoding.getByName` knows.
final Map<String, ResponseDecoder> _decoders = {
  for (final name in [
    'utf8', 'u8', 'utf', 'cp65001', 'csutf8', 'utf8ucs2', 'utf8ucs4', //
  ])
    name: utf8.decode,
  for (final name in [
    'ascii', 'usascii', '646', 'us', 'cp367', 'ibm367', 'csascii', //
    'iso646us', 'isoir6', 'ansix341968', 'ansix341986', 'iso646irv1991',
  ])
    name: ascii.decode,
  for (final name in [
    'latin1', 'latin', 'l1', 'iso88591', '88591', 'cp819', 'ibm819', //
    'csisolatin1', 'isoir100', 'iso885911987', '8859', 'iso8859',
  ])
    name: latin1.decode,
  for (final name in ['utf16', 'u16']) name: _utf16Bom,
  for (final name in ['utf16le', 'unicodelittleunmarked'])
    name: (bytes) => _utf16(bytes, Endian.little),
  for (final name in ['utf16be', 'unicodebigunmarked'])
    name: (bytes) => _utf16(bytes, Endian.big),
  for (final name in ['cp1252', 'windows1252']) name: _cp1252,
};

/// UTF-16 with an optional byte order mark; little-endian without one, as
/// Python decodes on the platforms it runs on.
String _utf16Bom(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(Uint8List.sublistView(bytes, 2), Endian.little);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(Uint8List.sublistView(bytes, 2), Endian.big);
    }
  }
  return _utf16(bytes, Endian.little);
}

String _utf16(Uint8List bytes, Endian endian) {
  if (bytes.length.isOdd) {
    throw const FormatException('Truncated UTF-16 data.');
  }
  final data = ByteData.sublistView(bytes);
  final units = [
    for (var i = 0; i < bytes.length; i += 2) data.getUint16(i, endian),
  ];
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) {
        throw const FormatException('Unpaired UTF-16 surrogate.');
      }
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      throw const FormatException('Unpaired UTF-16 surrogate.');
    }
  }
  return String.fromCharCodes(units);
}

/// Windows-1252 differs from Latin-1 in 0x80-0x9F; the five bytes it leaves
/// undefined fail, as in Python.
String _cp1252(Uint8List bytes) => String.fromCharCodes([
  for (final byte in bytes)
    if (byte < 0x80 || byte > 0x9F)
      byte
    else
      _cp1252High[byte - 0x80] ??
          (throw FormatException(
            'Byte 0x${byte.toRadixString(16)} is undefined in cp1252.',
          )),
]);

const _cp1252High = <int?>[
  0x20AC, null, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, null, 0x017D, null, //
  null, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, null, 0x017E, 0x0178, //
];
