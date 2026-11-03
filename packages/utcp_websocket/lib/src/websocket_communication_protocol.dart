import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connect.dart' if (dart.library.io) 'connect_io.dart';
import 'describe.dart';
import 'message.dart';
import 'websocket_call_template.dart';
import 'websocket_connection.dart';
import 'websocket_security.dart';

final _log = Logger('utcp.websocket');

const _keepAliveInterval = Duration(seconds: 30);

/// Opens the WebSocket for [template] at [uri] (the template URL with any
/// query-string auth applied), sending the handshake [headers]. An event on
/// [cancel] must abort a handshake in progress.
typedef WebSocketConnector =
    Future<WebSocketChannel> Function(
      Uri uri,
      Map<String, String> headers,
      WebSocketCallTemplate template,
      Stream<void> cancel,
    );

/// The `websocket` transport.
///
/// Discovery sends `{"type": "utcp"}` and waits for a text frame holding a
/// JSON object with `tools`, skipping other frames. A tool call sends one
/// text frame ([WebSocketCallTemplate.message]) and returns the next frame
/// received after it. A streaming call yields frames until
/// `{"type": "stream_end"}` or the server closes:
/// `{"type": "tool_response", "result": ...}` yields the result,
/// `{"type": "tool_error", "error": ...}` fails the call, and frames tagged
/// with a `request_id` are skipped, since this transport never sends one.
///
/// Connections stay open for reuse until the manual is deregistered (which
/// also aborts a connection to it still being opened) or the protocol is
/// closed, except that a call sending [WebSocketCallTemplate.headerFields]
/// gets a connection of its own, closed when the call ends. Responses carry
/// no correlation id, so exchanges on one connection run one at a time (a
/// call waits at most [WebSocketCallTemplate.timeout] for its turn), frames
/// that arrive outside an exchange are dropped, and a connection whose
/// exchange timed out or was cancelled is closed rather than reused. A
/// frame that arrives after the next call's message was sent is taken as
/// part of that call: nothing on the wire tells the two apart.
class WebSocketCommunicationProtocol extends CommunicationProtocol {
  /// [transport] fetches OAuth2 tokens; when given, the caller keeps
  /// ownership of it. [connector] replaces how sockets are opened, for
  /// example with in-memory channels; the URL and header checks still run
  /// before it.
  WebSocketCommunicationProtocol({
    HttpTransport? transport,
    WebSocketConnector? connector,
  }) : _transport = transport ?? HttpTransport(),
       _ownsTransport = transport == null,
       _connector = connector ?? _connectWebSocket;

  final HttpTransport _transport;
  final bool _ownsTransport;
  final WebSocketConnector _connector;

  /// Pooled connections, by [_key].
  final _connections = <String, WebSocketConnection>{};
  final _opening = <String, Future<WebSocketConnection>>{};

  /// Every open connection, pooled or not.
  final _live = <WebSocketConnection>{};

  /// Connection attempts in progress.
  final _attempts = <_Attempt>{};

  var _isClosed = false;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    WebSocketCallTemplate.type: WebSocketCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<WebSocketCallTemplate>(
      manualCallTemplate,
    );
    _Lease? lease;
    try {
      lease = await _lease(template, const {});
      final manual = await _discover(lease.connection, template);
      return RegisterManualResult(manualCallTemplate: template, manual: manual);
    } on Exception catch (e) {
      // A failed discovery must not leave the socket it opened in the pool.
      if (lease != null && lease.opened) await _drop(lease.connection);
      _log.warning("Discovery from '${template.name}' failed: $e");
      return RegisterManualResult.failure(template, [
        e is UtcpException ? e.message : '$e',
      ]);
    } finally {
      await lease?.release();
    }
  }

  Future<UtcpManual> _discover(
    WebSocketConnection connection,
    WebSocketCallTemplate template,
  ) async {
    final url = describeUrlString(template.url);
    connection.send(utcpDiscoveryMessage);
    final deadline = DateTime.now().add(template.timeout);
    while (true) {
      final message = await _next(
        connection,
        deadline,
        'Tool discovery from $url',
        template,
      );
      if (message == null) {
        throw UtcpException(
          'Failed to discover tools from $url: the connection closed before '
          'a manual arrived.',
        );
      }
      if (message is! String) continue;
      final Object? document;
      try {
        document = jsonDecode(message);
      } on FormatException {
        _log.warning("Skipping a non-JSON frame from '${template.name}'.");
        continue;
      }
      if (document is! Map<Object?, Object?> ||
          !document.containsKey('tools')) {
        continue;
      }
      final manual = UtcpManual.fromJson(
        asJsonMap(document, 'Discovery response'),
      );
      rejectRemoteLoopbackToolUrls(
        Uri.parse(template.url),
        manual,
        'manual discovery',
      );
      return manual;
    }
  }

  @override
  Future<void> deregisterManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    if (manualCallTemplate is! WebSocketCallTemplate) return;
    final key = _key(manualCallTemplate);
    final connecting = [
      for (final attempt in _attempts)
        if (attempt.key == key) attempt..abort(),
    ];
    await Future.wait([for (final attempt in connecting) attempt.settled]);
    final connection = _connections[key];
    if (connection != null) await _drop(connection);
  }

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final template = requireCallTemplate<WebSocketCallTemplate>(
      toolCallTemplate,
    );
    final (headers, rest) = _splitHeaderFields(template, arguments);
    final lease = await _lease(template, headers);
    try {
      lease.connection.send(formatMessage(template.message, rest));
      final message = await _next(
        lease.connection,
        DateTime.now().add(template.timeout),
        "Tool call '$toolName'",
        template,
      );
      if (message == null) {
        throw UtcpException(
          "The WebSocket closed before answering tool '$toolName'.",
        );
      }
      return decodeMessage(message, template.responseFormat);
    } finally {
      await lease.release();
    }
  }

  @override
  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async* {
    final template = requireCallTemplate<WebSocketCallTemplate>(
      toolCallTemplate,
    );
    final (headers, rest) = _splitHeaderFields(template, arguments);
    final lease = await _lease(template, headers);
    var finished = false;
    try {
      lease.connection.send(formatMessage(template.message, rest));
      final deadline = DateTime.now().add(template.timeout);
      while (true) {
        final message = await _next(
          lease.connection,
          deadline,
          "Streaming tool call '$toolName'",
          template,
        );
        if (message == null) {
          finished = true;
          return;
        }
        if (message is! String) {
          yield decodeMessage(message, template.responseFormat);
          continue;
        }
        final Object? frame;
        try {
          frame = jsonDecode(message);
        } on FormatException {
          yield message;
          continue;
        }
        if (frame is Map<Object?, Object?>) {
          final requestId = frame['request_id'];
          if (requestId != null && requestId != '') continue;
          switch (frame['type']) {
            case 'tool_response':
              yield frame['result'];
              continue;
            case 'tool_error':
              finished = true;
              throw UtcpException(
                "Tool '$toolName' failed: ${frame['error'] ?? 'Unknown error'}",
              );
            case 'stream_end':
              finished = true;
              return;
          }
        }
        yield message;
      }
    } finally {
      // Cancelled or failed mid-stream: the rest of the stream would be
      // read as the next call's answer.
      if (!finished) await _drop(lease.connection);
      await lease.release();
    }
  }

  /// Closes every connection and aborts handshakes in progress. The
  /// protocol cannot be used afterwards.
  @override
  Future<void> close() async {
    final first = !_isClosed;
    _isClosed = true;
    final connecting = [..._attempts];
    for (final attempt in connecting) {
      attempt.abort();
    }
    await Future.wait([
      for (final c in [..._live]) _drop(c),
    ]);
    await Future.wait([for (final attempt in connecting) attempt.settled]);
    if (first && _ownsTransport) _transport.close();
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw const UtcpException(
        'The WebSocket communication protocol is closed.',
      );
    }
  }

  /// The next frame within [deadline]; a timeout closes [connection].
  Future<Object?> _next(
    WebSocketConnection connection,
    DateTime deadline,
    String what,
    WebSocketCallTemplate template,
  ) async {
    try {
      return await connection.next(deadline);
    } on TimeoutException {
      await _drop(connection);
      throw UtcpException(
        '$what timed out after ${template.timeout.inSeconds} s.',
      );
    }
  }

  /// Arguments named in [WebSocketCallTemplate.headerFields] become
  /// handshake headers; the rest go into the message.
  static (Map<String, String>, ToolArguments) _splitHeaderFields(
    WebSocketCallTemplate template,
    ToolArguments arguments,
  ) {
    final rest = {...arguments};
    final headers = {
      for (final field in template.headerFields)
        if (rest.containsKey(field)) field: '${rest.remove(field)}',
    };
    return (headers, rest);
  }

  /// Identifies pooled connections whose handshakes would be identical.
  static String _key(WebSocketCallTemplate template) => jsonEncode([
    template.url,
    template.protocol,
    template.keepAlive,
    template.headers,
    template.auth?.toJson(),
  ]);

  /// A connection for [template], held exclusively until [_Lease.release].
  Future<_Lease> _lease(
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) async {
    _ensureOpen();
    ensureSecureWebSocketUrl(template.url, 'WebSocket connection');
    if (headers.isNotEmpty) {
      // Header field values are call arguments: pooling per value would
      // keep a socket open for every distinct value ever sent.
      final connection = await _open('', template, headers);
      final release = await connection.acquire(template.timeout);
      return _Lease(connection, () async {
        release();
        await _drop(connection);
      }, opened: true);
    }
    final key = _key(template);
    while (true) {
      _ensureOpen();
      var opened = false;
      var connection = _connections[key];
      if (connection == null || connection.isClosed) {
        if (connection != null) await _drop(connection);
        final pending = _opening[key];
        opened = pending == null;
        connection =
            await (pending ?? (_opening[key] = _openPooled(key, template)));
      }
      final void Function() release;
      try {
        release = await connection.acquire(template.timeout);
      } on TimeoutException {
        throw UtcpException(
          'Waiting for the WebSocket connection to '
          '${describeUrlString(template.url)} timed out after '
          '${template.timeout.inSeconds} s: earlier calls still hold it.',
        );
      }
      if (!connection.isClosed) {
        return _Lease(connection, () async => release(), opened: opened);
      }
      release();
      _ensureOpen();
      if (opened) {
        throw UtcpException(
          'The WebSocket at ${describeUrlString(template.url)} closed right '
          'after connecting.',
        );
      }
    }
  }

  Future<WebSocketConnection> _openPooled(
    String key,
    WebSocketCallTemplate template,
  ) async {
    try {
      return _connections[key] = await _open(key, template, const {});
    } finally {
      // Removing returns the future already being awaited by the caller.
      unawaited(_opening.remove(key));
    }
  }

  Future<WebSocketConnection> _open(
    String key,
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) {
    final attempt = _Attempt(key);
    _attempts.add(attempt);
    final connection = _connect(attempt, template, headers);
    attempt.settled = connection.then<void>((_) {}, onError: (Object _) {});
    unawaited(attempt.settled.whenComplete(() => _attempts.remove(attempt)));
    return connection;
  }

  Future<WebSocketConnection> _connect(
    _Attempt attempt,
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) async {
    final request = HttpRequestSpec(
      HttpMethod.get,
      Uri.parse(template.url),
      template.headers,
    );
    headers.forEach(request.setHeader);
    await _transport.authorize(
      request,
      template.auth,
      timeout: template.timeout,
    );
    final url = describeUrl(request.uri);
    _ensureNotAborted(attempt, url);
    final channel = await _connector(
      request.uri,
      request.headers,
      template,
      attempt.cancel.stream,
    );
    final connection = WebSocketConnection(attempt.key, channel);
    if (attempt.aborted) {
      // The connector completed a handshake it was asked to abort.
      await connection.close();
      _ensureNotAborted(attempt, url);
    }
    _live.add(connection);
    _log.fine('Connected to $url.');
    return connection;
  }

  void _ensureNotAborted(_Attempt attempt, String url) {
    _ensureOpen();
    if (attempt.aborted) {
      throw UtcpException('Connecting to $url was cancelled.');
    }
  }

  static Future<WebSocketChannel> _connectWebSocket(
    Uri uri,
    Map<String, String> headers,
    WebSocketCallTemplate template,
    Stream<void> cancel,
  ) => connectWebSocket(
    uri,
    headers: headers,
    protocol: template.protocol,
    pingInterval: template.keepAlive ? _keepAliveInterval : null,
    timeout: template.timeout,
    cancel: cancel,
  );

  Future<void> _drop(WebSocketConnection connection) async {
    if (identical(_connections[connection.key], connection)) {
      _connections.remove(connection.key);
    }
    _live.remove(connection);
    await connection.close();
  }
}

/// A connection attempt, aborted by [WebSocketCommunicationProtocol.close]
/// or by deregistering the manual it connects for.
final class _Attempt {
  _Attempt(this.key);

  /// The pool key, or `''` for a connection of a call's own.
  final String key;

  /// Emits once, on [abort], to cancel the handshake.
  final cancel = StreamController<void>.broadcast(sync: true);
  bool aborted = false;

  /// Completes, never with an error, once the attempt has finished.
  late final Future<void> settled;

  void abort() {
    if (aborted) return;
    aborted = true;
    cancel.add(null);
    unawaited(cancel.close());
  }
}

final class _Lease {
  _Lease(this.connection, this.release, {required this.opened});

  final WebSocketConnection connection;

  /// Ends the exchange and hands the connection to the next holder, or
  /// closes it when it is not pooled.
  final Future<void> Function() release;

  /// Whether this lease opened [connection] rather than reusing it.
  final bool opened;
}
