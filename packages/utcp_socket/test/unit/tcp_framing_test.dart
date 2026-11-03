import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/src/tcp_framing.dart';
import 'package:utcp_socket/utcp_socket.dart';

TcpCallTemplate _tcp(
  TcpFramingStrategy framing, {
  int prefixBytes = 4,
  LengthPrefixEndian endian = LengthPrefixEndian.big,
  String delimiter = r'\n',
  int? fixedLength,
  int maxResponseSize = 65536,
  Duration timeout = const Duration(seconds: 5),
}) => TcpCallTemplate(
  host: 'h',
  port: 1,
  framingStrategy: framing,
  lengthPrefixBytes: prefixBytes,
  lengthPrefixEndian: endian,
  messageDelimiter: delimiter,
  fixedMessageLength: fixedLength,
  maxResponseSize: maxResponseSize,
  timeout: timeout,
);

Future<List<int>> _read(
  Stream<List<int>> input,
  TcpCallTemplate template, {
  int maxFrameBytes = 65536,
}) => readFrame(input, template, maxFrameBytes: maxFrameBytes);

/// Feeds [chunks] one read at a time, then closes.
Stream<List<int>> _reads(List<List<int>> chunks) => Stream.fromIterable(chunks);

/// Splits [bytes] into one-byte reads.
Stream<List<int>> _byteByByte(List<int> bytes) => _reads([
  for (final b in bytes) [b],
]);

void main() {
  group('encodeFrame', () {
    final payload = utf8.encode('hi');

    test('length prefix in every size and byte order', () {
      expect(encodeFrame(payload, _tcp(TcpFramingStrategy.lengthPrefix)), [
        0,
        0,
        0,
        2,
        104,
        105,
      ]);
      expect(
        encodeFrame(
          payload,
          _tcp(
            TcpFramingStrategy.lengthPrefix,
            prefixBytes: 2,
            endian: LengthPrefixEndian.little,
          ),
        ),
        [2, 0, 104, 105],
      );
      expect(
        encodeFrame(
          payload,
          _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 1),
        ),
        [2, 104, 105],
      );
      expect(
        encodeFrame(
          payload,
          _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 8),
        ),
        [0, 0, 0, 0, 0, 0, 0, 2, 104, 105],
      );
    });

    test('a request too long for its prefix is rejected', () {
      expect(
        () => encodeFrame(
          List.filled(256, 0),
          _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 1),
        ),
        throwsA(isA<UtcpException>()),
      );
    });

    test('delimiter is appended; fixed and stream send the payload alone', () {
      expect(
        encodeFrame(
          payload,
          _tcp(TcpFramingStrategy.delimiter, delimiter: r'\r\n'),
        ),
        [104, 105, 13, 10],
      );
      expect(
        encodeFrame(
          payload,
          _tcp(TcpFramingStrategy.fixedLength, fixedLength: 2),
        ),
        payload,
      );
      expect(encodeFrame(payload, _tcp(TcpFramingStrategy.stream)), payload);
    });
  });

  group('readFrame', () {
    test('length prefix across partial reads, ignoring what follows', () async {
      final template = _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 2);
      final wire = [0, 5, ...utf8.encode('hello'), 0, 3, 1, 2, 3];
      expect(utf8.decode(await _read(_byteByByte(wire), template)), 'hello');
      expect(utf8.decode(await _read(_reads([wire]), template)), 'hello');
    });

    test('little-endian and 8-byte prefixes', () async {
      final little = _tcp(
        TcpFramingStrategy.lengthPrefix,
        endian: LengthPrefixEndian.little,
      );
      expect(
        await _read(
          _reads([
            [2, 0, 0, 0, 7, 8],
          ]),
          little,
        ),
        [7, 8],
      );
      final wide = _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 8);
      expect(
        await _read(
          _reads([
            [0, 0, 0, 0, 0, 0, 0, 1, 9],
          ]),
          wide,
        ),
        [9],
      );
    });

    test('a declared length over the frame limit fails fast', () async {
      final template = _tcp(TcpFramingStrategy.lengthPrefix);
      await expectLater(
        _read(
          _reads([
            [0, 0, 0, 11],
          ]),
          template,
          maxFrameBytes: 10,
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('maxFrameBytes'),
          ),
        ),
      );
      final wide = _tcp(TcpFramingStrategy.lengthPrefix, prefixBytes: 8);
      await expectLater(
        _read(
          _reads([
            [0xff, 0, 0, 0, 0, 0, 0, 0],
          ]),
          wide,
        ),
        throwsA(isA<UtcpException>()),
      );
    });

    test('delimiter split across reads, first message wins', () async {
      final template = _tcp(TcpFramingStrategy.delimiter, delimiter: r'\r\n');
      expect(
        utf8.decode(
          await _read(
            _reads([utf8.encode('one\r'), utf8.encode('\ntwo\r\n')]),
            template,
          ),
        ),
        'one',
      );
      expect(
        utf8.decode(await _read(_reads([utf8.encode('a\r\nb\r\n')]), template)),
        'a',
      );
      expect(
        utf8.decode(await _read(_byteByByte(utf8.encode('xyz\r\n')), template)),
        'xyz',
      );
    });

    test('delimiter missing within the frame limit fails', () async {
      final template = _tcp(TcpFramingStrategy.delimiter);
      await expectLater(
        _read(_reads([utf8.encode('abcdef')]), template, maxFrameBytes: 4),
        throwsA(isA<UtcpException>()),
      );
      // Exactly max bytes plus the delimiter still fits.
      expect(
        utf8.decode(
          await _read(
            _reads([utf8.encode('abcd\n')]),
            template,
            maxFrameBytes: 4,
          ),
        ),
        'abcd',
      );
    });

    test('a delimited frame over the frame limit fails', () async {
      final template = _tcp(TcpFramingStrategy.delimiter);
      for (final read in [
        _reads([utf8.encode('abcdef\n')]),
        _byteByByte(utf8.encode('abcde\n')),
      ]) {
        await expectLater(
          _read(read, template, maxFrameBytes: 4),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('maxFrameBytes'),
            ),
          ),
        );
      }
    });

    test('a fixed length over the frame limit fails', () async {
      await expectLater(
        _read(
          _reads([List.filled(8, 1)]),
          _tcp(TcpFramingStrategy.fixedLength, fixedLength: 8),
          maxFrameBytes: 4,
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('maxFrameBytes'),
          ),
        ),
      );
    });

    test('max_response_size bounds only stream framing', () async {
      final big = List.filled(100, 7);
      final frames = {
        _tcp(TcpFramingStrategy.lengthPrefix, maxResponseSize: 10): [
          ...[0, 0, 0, 100],
          ...big,
        ],
        _tcp(TcpFramingStrategy.delimiter, maxResponseSize: 10): [
          ...big,
          ...utf8.encode('\n'),
        ],
        _tcp(
          TcpFramingStrategy.fixedLength,
          fixedLength: 100,
          maxResponseSize: 10,
        ): big,
      };
      for (final MapEntry(key: template, value: wire) in frames.entries) {
        expect(
          await _read(_reads([wire]), template),
          big,
          reason: template.framingStrategy.wireName,
        );
      }
    });

    test('fixed length reads exactly that many bytes', () async {
      final template = _tcp(TcpFramingStrategy.fixedLength, fixedLength: 3);
      expect(await _read(_byteByByte([1, 2, 3, 4]), template), [1, 2, 3]);
    });

    test('stream reads to close and truncates at max_response_size', () async {
      expect(
        await _read(
          _reads([
            [1, 2],
            [3],
          ]),
          _tcp(TcpFramingStrategy.stream),
        ),
        [1, 2, 3],
      );
      expect(await _read(_reads([]), _tcp(TcpFramingStrategy.stream)), isEmpty);
      expect(
        await _read(
          _reads([
            [1, 2],
            [3, 4, 5],
          ]),
          _tcp(TcpFramingStrategy.stream, maxResponseSize: 4),
        ),
        [1, 2, 3, 4],
      );
    });

    test('a connection closed mid-frame is an error', () async {
      for (final template in [
        _tcp(TcpFramingStrategy.lengthPrefix),
        _tcp(TcpFramingStrategy.delimiter),
        _tcp(TcpFramingStrategy.fixedLength, fixedLength: 4),
      ]) {
        await expectLater(
          _read(
            _reads([
              [0, 0, 0],
            ]),
            template,
          ),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
          reason: template.framingStrategy.wireName,
        );
      }
    });

    test(
      'idle timeout ends a stream response but fails other framings',
      () async {
        const idle = Duration(milliseconds: 50);
        final open = StreamController<List<int>>();
        addTearDown(open.close);
        open.add([1, 2]);
        expect(
          await _read(
            open.stream,
            _tcp(TcpFramingStrategy.stream, timeout: idle),
          ),
          [1, 2],
        );

        final silent = StreamController<List<int>>();
        addTearDown(silent.close);
        silent.add([1]);
        await expectLater(
          _read(
            silent.stream,
            _tcp(TcpFramingStrategy.delimiter, timeout: idle),
          ),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
      },
    );

    test('a read error propagates', () async {
      await expectLater(
        _read(
          Stream.error(const FormatException('boom')),
          _tcp(TcpFramingStrategy.stream),
        ),
        throwsFormatException,
      );
    });
  });
}
