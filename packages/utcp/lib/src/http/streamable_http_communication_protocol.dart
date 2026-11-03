import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../client.dart';
import '../communication_protocol.dart';
import '../data/call_template.dart';
import '../data/tool.dart';
import '../data/utcp_manual.dart';
import '../exceptions.dart';
import '../registry.dart';
import 'discovery.dart';
import 'http_transport.dart';
import 'streamable_http_call_template.dart';

final _log = Logger('utcp.streamable_http');

/// The `streamable_http` transport: one request whose response body is
/// yielded as it arrives.
///
/// The response Content-Type decides the chunks: `application/x-ndjson`
/// yields one value per line (the raw line when it is not JSON),
/// `application/json` yields the whole body as one value (the raw bytes when
/// it is not JSON), and anything else yields [Uint8List] chunks of at most
/// [StreamableHttpCallTemplate.chunkSize] bytes.
class StreamableHttpCommunicationProtocol extends CommunicationProtocol {
  /// When [transport] is given, the caller keeps ownership of it.
  StreamableHttpCommunicationProtocol({
    HttpTransport? transport,
    this.discoveryTimeout = const Duration(seconds: 10),
    this.maxLineChars = 16 * 1024 * 1024,
  }) : _transport = transport ?? HttpTransport(),
       _ownsTransport = transport == null;

  final HttpTransport _transport;
  final bool _ownsTransport;

  /// Limit for manual discovery, including reading the response body.
  final Duration discoveryTimeout;

  /// Longest NDJSON line, in UTF-16 code units, before the stream is
  /// declared malformed.
  final int maxLineChars;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    StreamableHttpCallTemplate.type: StreamableHttpCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) {
    final template = requireCallTemplate<StreamableHttpCallTemplate>(
      manualCallTemplate,
    );
    return discoverManual(
      _transport,
      template,
      method: template.httpMethod,
      timeout: discoveryTimeout,
      log: _log,
    );
  }

  /// Reads the whole response: byte chunks are joined into one [Uint8List],
  /// decoded chunks are returned as a list.
  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final chunks = await callToolStreaming(
      caller,
      toolName,
      arguments,
      toolCallTemplate,
    ).toList();
    if (!chunks.any((chunk) => chunk is Uint8List)) return chunks;
    final bytes = BytesBuilder(copy: false);
    for (final chunk in chunks.whereType<Uint8List>()) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) => abortOnCancel(
    (cancel) => _stream(
      toolName,
      arguments,
      requireCallTemplate<StreamableHttpCallTemplate>(toolCallTemplate),
      cancel,
    ),
  );

  Stream<Object?> _stream(
    String toolName,
    ToolArguments arguments,
    StreamableHttpCallTemplate template,
    Future<void> cancel,
  ) async* {
    final request = buildToolRequest(template, arguments);
    final stop = Completer<void>();
    var timedOut = false;
    final deadline = Timer(template.timeout, () {
      timedOut = true;
      if (!stop.isCompleted) stop.complete();
    });
    cancel.whenComplete(() {
      if (!stop.isCompleted) stop.complete();
    }).ignore();
    try {
      await _transport.authorize(
        request,
        template.auth,
        timeout: template.timeout,
      );
      final response = await _transport.open(
        request,
        context: 'tool invocation',
        timeout: template.timeout,
        errorContext: "calling tool '$toolName'",
        abortTrigger: stop.future,
      );
      await for (final chunk in _chunks(response, template.chunkSize)) {
        yield chunk;
      }
    } on http.RequestAbortedException {
      // Otherwise the listener cancelled and nobody is left to tell.
      if (timedOut) {
        throw UtcpException(
          'Timed out after ${template.timeout.inMilliseconds} ms during tool '
          'invocation.',
        );
      }
    } finally {
      deadline.cancel();
    }
  }

  Stream<Object?> _chunks(HttpStreamedResult response, int chunkSize) {
    final contentType = response.contentType.toLowerCase();
    if (contentType.contains('application/x-ndjson')) {
      return _ndjson(response.body);
    }
    if (contentType.contains('application/json')) {
      return _json(response.body);
    }
    return response.body.expand((chunk) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      return [
        for (var start = 0; start < bytes.length; start += chunkSize)
          Uint8List.sublistView(
            bytes,
            start,
            min(start + chunkSize, bytes.length),
          ),
      ];
    });
  }

  Stream<Object?> _ndjson(Stream<List<int>> body) async* {
    // A buffer rather than string concatenation keeps a long line split
    // across many chunks linear to assemble.
    final partial = StringBuffer();
    await for (final text in body.transform(
      const Utf8Decoder(allowMalformed: true),
    )) {
      var start = 0;
      for (
        var newline = text.indexOf('\n');
        newline >= 0;
        newline = text.indexOf('\n', start)
      ) {
        partial.write(text.substring(start, newline));
        start = newline + 1;
        final line = partial.toString();
        partial.clear();
        _checkLine(line.length);
        if (line.trim().isNotEmpty) yield _decodeLine(line);
      }
      partial.write(text.substring(start));
      _checkLine(partial.length);
    }
    final rest = partial.toString();
    if (rest.trim().isNotEmpty) yield _decodeLine(rest);
  }

  void _checkLine(int length) {
    if (length > maxLineChars) {
      throw UtcpException(
        'NDJSON line exceeded $maxLineChars characters without a newline.',
      );
    }
  }

  static Object? _decodeLine(String line) {
    final text = line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  static Stream<Object?> _json(Stream<List<int>> body) async* {
    final bytes = await http.ByteStream(body).toBytes();
    if (bytes.isEmpty) return;
    try {
      yield jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      yield bytes;
    }
  }

  @override
  Future<void> close() async {
    if (_ownsTransport) _transport.close();
  }
}
