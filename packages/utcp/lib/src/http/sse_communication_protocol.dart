import 'dart:async';
import 'dart:convert';

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
import 'http_call_template.dart';
import 'http_transport.dart';
import 'sse_call_template.dart';
import 'sse_parser.dart';

final _log = Logger('utcp.sse');

/// The `sse` transport: a tool call reads a Server-Sent Events stream and
/// yields the `data` of each event, JSON-decoded when it parses and as a
/// string otherwise.
///
/// A stream that drops is reopened with `Last-Event-ID` when the template
/// allows it, at most [maxReconnectAttempts] times per call. The first
/// handshake failing, an HTTP error, or a response that is not
/// `text/event-stream` fails the call at once.
class SseCommunicationProtocol extends CommunicationProtocol {
  /// When [transport] is given, the caller keeps ownership of it.
  SseCommunicationProtocol({
    HttpTransport? transport,
    this.discoveryTimeout = const Duration(seconds: 10),
    this.handshakeTimeout = const Duration(seconds: 30),
    this.maxEventChars = 16 * 1024 * 1024,
  }) : _transport = transport ?? HttpTransport(),
       _ownsTransport = transport == null;

  final HttpTransport _transport;
  final bool _ownsTransport;

  /// Limit for manual discovery, including reading the response body.
  final Duration discoveryTimeout;

  /// Limit until response headers (or an error body) arrive, and for token
  /// requests. Reading the stream itself is not time-limited, since an event
  /// stream may stay quiet.
  final Duration handshakeTimeout;

  /// Largest event, in UTF-16 code units, buffered before the stream is
  /// declared malformed.
  final int maxEventChars;

  static const maxReconnectAttempts = 5;

  /// Cap on the wait before a reconnect, whatever the template or a
  /// server-sent `retry:` field asks for.
  static const maxReconnectDelay = Duration(seconds: 60);

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    SseCallTemplate.type: SseCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) => discoverManual(
    _transport,
    requireCallTemplate<SseCallTemplate>(manualCallTemplate),
    method: HttpMethod.get,
    timeout: discoveryTimeout,
    log: _log,
  );

  /// Reads the whole stream and returns the event payloads as a list.
  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) =>
      callToolStreaming(caller, toolName, arguments, toolCallTemplate).toList();

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
      requireCallTemplate<SseCallTemplate>(toolCallTemplate),
      cancel,
    ),
  );

  Stream<Object?> _stream(
    String toolName,
    ToolArguments arguments,
    SseCallTemplate template,
    Future<void> cancel,
  ) async* {
    final request = buildToolRequest(
      template,
      arguments,
      getWithBody: GetWithBody.sendAsPost,
    );
    final sendsBody = request.body != null;
    request.setHeader('Accept', 'text/event-stream');
    await _transport.authorize(
      request,
      template.auth,
      timeout: handshakeTimeout,
    );
    // Re-issuing a request with a body could run a non-idempotent tool twice.
    final reconnect = template.reconnect && !sendsBody;
    var retryDelay = template.retryTimeout;
    var attempts = 0;

    while (true) {
      final HttpStreamedResult response;
      try {
        response = await _handshake(request, toolName, cancel);
      } on http.RequestAbortedException {
        return;
      } on SseProtocolException {
        rethrow;
      } on UtcpSecurityException {
        rethrow;
      } on Exception catch (e) {
        // The first handshake failing is a definitive answer about the
        // endpoint; a failed reconnect is part of the outage being ridden out.
        if (attempts == 0 || ++attempts > maxReconnectAttempts) rethrow;
        _log.warning(
          "SSE reconnect for '$toolName' failed (attempt $attempts/"
          '$maxReconnectAttempts): $e',
        );
        if (await _waitUnlessCancelled(retryDelay, cancel)) return;
        continue;
      }

      try {
        await for (final event in parseSseEvents(
          response.body,
          maxEventChars: maxEventChars,
        )) {
          switch (event.id) {
            case null:
              break;
            case '':
              request.removeHeader('Last-Event-ID');
            case final id:
              request.setHeader('Last-Event-ID', id);
          }
          if (event.retry case final retry?) {
            retryDelay = Duration(milliseconds: retry);
          }
          final data = event.data;
          if (data != null && _matches(event, template.eventType)) {
            yield _decode(data);
          }
        }
        return;
      } on http.RequestAbortedException {
        return;
      } on UtcpException {
        rethrow;
      } on Exception catch (e) {
        if (!reconnect || ++attempts > maxReconnectAttempts) rethrow;
        _log.warning(
          "SSE stream for '$toolName' dropped, reconnecting (attempt "
          '$attempts/$maxReconnectAttempts): $e',
        );
      }
      if (await _waitUnlessCancelled(retryDelay, cancel)) return;
    }
  }

  Future<HttpStreamedResult> _handshake(
    HttpRequestSpec request,
    String toolName,
    Future<void> cancel,
  ) async {
    final response = await _transport.open(
      request,
      context: 'tool invocation',
      timeout: handshakeTimeout,
      errorContext: "calling tool '$toolName'",
      abortTrigger: cancel,
    );
    final contentType = response.contentType;
    // An exact media type match: a JSON error document would otherwise parse
    // into zero events and a "successful" call.
    if (contentType.split(';').first.trim().toLowerCase() !=
        'text/event-stream') {
      await response.discard();
      throw SseProtocolException(
        "Expected a text/event-stream response from tool '$toolName', got "
        '${contentType.isEmpty ? 'no Content-Type' : "'$contentType'"}.',
      );
    }
    return response;
  }

  static bool _matches(SseEvent event, String? eventType) {
    if (eventType == null || eventType.isEmpty) return true;
    final type = event.event;
    return (type == null || type.isEmpty ? 'message' : type) == eventType;
  }

  static Object? _decode(String data) {
    try {
      return jsonDecode(data);
    } on FormatException {
      return data;
    }
  }

  /// Waits [delay], capped at [maxReconnectDelay]. Returns `true` when
  /// [cancel] fires first.
  static Future<bool> _waitUnlessCancelled(
    Duration delay,
    Future<void> cancel,
  ) {
    final result = Completer<bool>();
    final timer = Timer(
      delay > maxReconnectDelay ? maxReconnectDelay : delay,
      () {
        if (!result.isCompleted) result.complete(false);
      },
    );
    cancel.then((_) {
      timer.cancel();
      if (!result.isCompleted) result.complete(true);
    }).ignore();
    return result.future;
  }

  @override
  Future<void> close() async {
    if (_ownsTransport) _transport.close();
  }
}
