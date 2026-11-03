import 'dart:async';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'tcp_call_template.dart';

/// Frames [payload] for sending per [template]'s framing strategy.
Uint8List encodeFrame(List<int> payload, TcpCallTemplate template) {
  final bytes = BytesBuilder(copy: false);
  switch (template.framingStrategy) {
    case TcpFramingStrategy.lengthPrefix:
      bytes.add(_lengthPrefix(payload.length, template));
      bytes.add(payload);
    case TcpFramingStrategy.delimiter:
      bytes.add(payload);
      bytes.add(template.delimiterBytes);
    case TcpFramingStrategy.fixedLength || TcpFramingStrategy.stream:
      bytes.add(payload);
  }
  return bytes.takeBytes();
}

Uint8List _lengthPrefix(int length, TcpCallTemplate template) {
  final size = template.lengthPrefixBytes;
  if (size < 8 && length >= 1 << (8 * size)) {
    throw UtcpException(
      'Request of $length bytes does not fit a $size-byte length prefix.',
    );
  }
  final prefix = ByteData(size);
  final endian = template.lengthPrefixEndian.endian;
  switch (size) {
    case 1:
      prefix.setUint8(0, length);
    case 2:
      prefix.setUint16(0, length, endian);
    case 4:
      prefix.setUint32(0, length, endian);
    case 8:
      prefix.setUint64(0, length, endian);
    default:
      throw ArgumentError.value(size, 'lengthPrefixBytes', 'Must be 1-8');
  }
  return prefix.buffer.asUint8List();
}

/// Reads one response from [input] per [template]'s framing strategy,
/// handling messages split across reads. Bytes after the frame are ignored.
///
/// [TcpCallTemplate.timeout] is an idle limit, as in the Python transport:
/// it bounds each wait for data rather than the whole response. In stream
/// framing, going idle ends the response; otherwise it is an error.
Future<Uint8List> readFrame(
  Stream<List<int>> input,
  TcpCallTemplate template,
) async {
  final stream = template.framingStrategy == TcpFramingStrategy.stream
      ? input.timeout(template.timeout, onTimeout: (sink) => sink.close())
      : input.timeout(template.timeout);
  final reader = _FrameReader(template);
  try {
    await for (final chunk in stream) {
      final frame = reader.add(chunk);
      if (frame != null) return frame;
    }
  } on TimeoutException {
    throw UtcpException(
      'TCP response timed out after ${template.timeout.inMilliseconds} ms '
      'without data.',
    );
  }
  return reader.closed();
}

final class _FrameReader {
  _FrameReader(this.template)
    : _delimiter = template.framingStrategy == TcpFramingStrategy.delimiter
          ? template.delimiterBytes
          : const [];

  final TcpCallTemplate template;
  final List<int> _delimiter;
  final _data = <int>[];

  int get _max => template.maxResponseSize;

  /// Returns the frame once [chunk] completes it.
  Uint8List? add(List<int> chunk) {
    final searchFrom = _data.length - _delimiter.length + 1;
    _data.addAll(chunk);
    switch (template.framingStrategy) {
      case TcpFramingStrategy.lengthPrefix:
        final size = template.lengthPrefixBytes;
        if (_data.length < size) return null;
        final length = _readLength(size);
        // An 8-byte length of 2^63 or more reads as negative.
        if (length < 0 || length > _max) {
          throw _oversized(
            'declares ${length < 0 ? 'over 2^63' : length} bytes',
          );
        }
        return _data.length - size >= length
            ? _take(size, size + length)
            : null;
      case TcpFramingStrategy.delimiter:
        final end = _indexOfDelimiter(searchFrom < 0 ? 0 : searchFrom);
        if (end != -1) return _take(0, end);
        if (_data.length > _max + _delimiter.length) {
          throw _oversized('has no delimiter in the first $_max bytes');
        }
        return null;
      case TcpFramingStrategy.fixedLength:
        final length = template.fixedMessageLength!;
        return _data.length >= length ? _take(0, length) : null;
      case TcpFramingStrategy.stream:
        return _data.length >= _max ? _take(0, _max) : null;
    }
  }

  /// The frame when the connection ends before [add] completed one.
  Uint8List closed() {
    if (template.framingStrategy == TcpFramingStrategy.stream) {
      return Uint8List.fromList(_data);
    }
    throw UtcpException(
      'TCP connection closed after ${_data.length} bytes, before a complete '
      '${template.framingStrategy.wireName} response.',
    );
  }

  int _readLength(int size) {
    final prefix = ByteData.sublistView(
      Uint8List.fromList(_data.sublist(0, size)),
    );
    final endian = template.lengthPrefixEndian.endian;
    return switch (size) {
      1 => prefix.getUint8(0),
      2 => prefix.getUint16(0, endian),
      4 => prefix.getUint32(0, endian),
      _ => prefix.getUint64(0, endian),
    };
  }

  int _indexOfDelimiter(int from) {
    outer:
    for (var i = from; i <= _data.length - _delimiter.length; i++) {
      for (var j = 0; j < _delimiter.length; j++) {
        if (_data[i + j] != _delimiter[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  Uint8List _take(int start, int end) =>
      Uint8List.fromList(_data.sublist(start, end));

  UtcpException _oversized(String detail) => UtcpException(
    'TCP response $detail, more than max_response_size ($_max).',
  );
}
