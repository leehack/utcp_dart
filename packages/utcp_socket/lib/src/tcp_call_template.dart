import 'dart:convert';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'escapes.dart';
import 'socket_call_template.dart';

/// How request and response messages are delimited on the TCP stream.
enum TcpFramingStrategy {
  /// Each message is preceded by its byte length.
  lengthPrefix('length_prefix'),

  /// Each message is followed by [TcpCallTemplate.messageDelimiter].
  delimiter('delimiter'),

  /// The response is exactly [TcpCallTemplate.fixedMessageLength] bytes.
  fixedLength('fixed_length'),

  /// The response runs until the server closes the connection, goes quiet
  /// for [SocketCallTemplate.timeout], or reaches
  /// [TcpCallTemplate.maxResponseSize].
  stream('stream');

  const TcpFramingStrategy(this.wireName);

  final String wireName;

  static TcpFramingStrategy parse(String value) => values.firstWhere(
    (s) => s.wireName == value,
    orElse: () => throw FormatException("Invalid framing_strategy '$value'."),
  );
}

/// Byte order of a length prefix.
enum LengthPrefixEndian {
  big(Endian.big),
  little(Endian.little);

  const LengthPrefixEndian(this.endian);

  final Endian endian;

  static LengthPrefixEndian parse(String value) =>
      values.asNameMap()[value] ??
      (throw FormatException("Invalid length_prefix_endian '$value'."));
}

/// Calls a tool, or fetches a manual, over one TCP connection per request.
class TcpCallTemplate extends SocketCallTemplate {
  const TcpCallTemplate({
    super.name,
    required super.host,
    required super.port,
    super.requestDataFormat,
    super.requestDataTemplate,
    super.responseByteFormat,
    this.framingStrategy = TcpFramingStrategy.stream,
    this.lengthPrefixBytes = 4,
    this.lengthPrefixEndian = LengthPrefixEndian.big,
    this.messageDelimiter = '\x00',
    this.interpretEscapeSequences = true,
    this.fixedMessageLength,
    this.maxResponseSize = 65536,
    super.timeout,
    super.allowedCommunicationProtocols,
  });

  factory TcpCallTemplate.fromJson(JsonMap json) {
    json.rejectAuth(type);
    final framing = TcpFramingStrategy.parse(
      json.optString('framing_strategy') ?? 'stream',
    );
    final prefixBytes = json.optInt('length_prefix_bytes') ?? 4;
    if (!lengthPrefixSizes.contains(prefixBytes)) {
      throw FormatException(
        "Field 'length_prefix_bytes' must be 1, 2, 4 or 8, got $prefixBytes.",
      );
    }
    final fixedLength = json.positiveInt('fixed_message_length');
    if (framing == TcpFramingStrategy.fixedLength && fixedLength == null) {
      throw const FormatException(
        "Field 'fixed_message_length' is required for fixed_length framing.",
      );
    }
    final template = TcpCallTemplate(
      name: json.optString('name'),
      host: json.string('host'),
      port: json.socketPort,
      requestDataFormat: json.requestDataFormat,
      requestDataTemplate: json.optString('request_data_template'),
      responseByteFormat: json.responseByteFormat,
      framingStrategy: framing,
      lengthPrefixBytes: prefixBytes,
      lengthPrefixEndian: LengthPrefixEndian.parse(
        json.optString('length_prefix_endian') ?? 'big',
      ),
      messageDelimiter: json.optString('message_delimiter') ?? '\x00',
      interpretEscapeSequences:
          json.optBool('interpret_escape_sequences') ?? true,
      fixedMessageLength: fixedLength,
      maxResponseSize: json.positiveInt('max_response_size') ?? 65536,
      timeout: json.socketTimeout,
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
    // Fails on a malformed escape now rather than on the first call.
    template.delimiterBytes;
    return template;
  }

  static const type = 'tcp';

  static const lengthPrefixSizes = {1, 2, 4, 8};

  final TcpFramingStrategy framingStrategy;

  /// Size of the length prefix: 1, 2, 4 or 8 bytes.
  final int lengthPrefixBytes;
  final LengthPrefixEndian lengthPrefixEndian;

  /// Ends each message in [TcpFramingStrategy.delimiter] framing. An empty
  /// delimiter means NUL.
  final String messageDelimiter;

  /// Whether Python-style escapes in [messageDelimiter] (`\n`, `\x00`, ...)
  /// are interpreted, rather than sent literally.
  final bool interpretEscapeSequences;

  /// Response size in [TcpFramingStrategy.fixedLength] framing.
  final int? fixedMessageLength;

  /// Most bytes read for a [TcpFramingStrategy.stream] response, which
  /// stops there. Other framings are bounded by
  /// `TcpCommunicationProtocol.maxFrameBytes`, as in the Python SDK, where
  /// this field applies to stream framing only.
  final int maxResponseSize;

  @override
  String get callTemplateType => type;

  /// The UTF-8 bytes of [messageDelimiter], escapes interpreted when
  /// [interpretEscapeSequences] is set. Throws a [FormatException] for a
  /// malformed escape.
  List<int> get delimiterBytes {
    final delimiter = messageDelimiter.isEmpty ? '\x00' : messageDelimiter;
    return utf8.encode(
      interpretEscapeSequences ? interpretEscapes(delimiter) : delimiter,
    );
  }

  @override
  JsonMap fieldsToJson() => {
    ...socketFieldsToJson(),
    'framing_strategy': framingStrategy.wireName,
    'length_prefix_bytes': lengthPrefixBytes,
    'length_prefix_endian': lengthPrefixEndian.name,
    'message_delimiter': messageDelimiter,
    'interpret_escape_sequences': interpretEscapeSequences,
    'fixed_message_length': ?fixedMessageLength,
    'max_response_size': maxResponseSize,
  };
}
