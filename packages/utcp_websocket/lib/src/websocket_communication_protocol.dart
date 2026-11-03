import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:utcp/utcp.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connect.dart' if (dart.library.io) 'connect_io.dart';
import 'message.dart';
import 'websocket_call_template.dart';
import 'websocket_security.dart';

final _log = Logger('utcp.websocket');

const _keepAliveInterval = Duration(seconds: 30);

/// The `websocket` transport.
///
/// Discovery sends `{"type": "utcp"}` and waits for a text frame holding a
/// JSON object with `tools`, skipping other frames. A tool call sends one
/// text frame ([WebSocketCallTemplate.message]) and returns the next frame
/// received. A streaming call yields frames until `{"type": "stream_end"}`
/// or the server closes: `{"type": "tool_response", "result": ...}` yields
/// the result, `{"type": "tool_error", "error": ...}` fails the call, and
/// frames tagged with a `request_id` are skipped, since this transport never
/// sends one.
///
/// Connections stay open for reuse until the manual is deregistered or the
/// protocol is closed. Responses carry no correlation id, so exchanges on
/// one connection run one at a time, and a connection whose exchange timed
/// out or was cancelled is closed rather than reused: a late answer would
/// otherwise be taken as the next call's result.
class WebSocketCommunicationProtocol extends CommunicationProtocol {
  /// [transport] fetches OAuth2 tokens; when given, the caller keeps
  /// ownership of it.
  WebSocketCommunicationProtocol({HttpTransport? transport})
    : _transport = transport ?? HttpTransport(),
      _ownsTransport = transport == null;

  final HttpTransport _transport;
  final bool _ownsTransport;
  final _connections = <String, _Connection>{};
  final _opening = <String, Future<_Connection>>{};

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
      lease?.release();
    }
  }

  Future<UtcpManual> _discover(
    _Connection connection,
    WebSocketCallTemplate template,
  ) async {
    connection.send(discoveryMessage);
    final deadline = DateTime.now().add(template.timeout);
    while (true) {
      final message = await _next(
        connection,
        deadline,
        'Tool discovery from ${template.url}',
        template,
      );
      if (message == null) {
        throw UtcpException(
          'Failed to discover tools from ${template.url}: the connection '
          'closed before a manual arrived.',
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
      rejectRemoteLoopbackWebSocketTools(
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
    final connection = _connections[_key(manualCallTemplate, const {})];
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
      lease.release();
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
      lease.release();
    }
  }

  @override
  Future<void> close() async {
    await Future.wait([
      for (final connection in [..._connections.values]) _drop(connection),
    ]);
    if (_ownsTransport) _transport.close();
  }

  /// The next frame within [deadline]; a timeout closes [connection].
  Future<Object?> _next(
    _Connection connection,
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

  /// Identifies connections whose handshakes would be identical.
  static String _key(
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) => jsonEncode([
    template.url,
    template.protocol,
    template.keepAlive,
    template.headers,
    template.auth?.toJson(),
    headers,
  ]);

  /// An open connection for [template], held exclusively until
  /// [_Lease.release].
  Future<_Lease> _lease(
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) async {
    ensureSecureWebSocketUrl(template.url, 'WebSocket connection');
    final key = _key(template, headers);
    while (true) {
      var opened = false;
      var connection = _connections[key];
      if (connection == null || connection.isClosed) {
        if (connection != null) await _drop(connection);
        final pending = _opening[key];
        opened = pending == null;
        connection =
            await (pending ?? (_opening[key] = _open(key, template, headers)));
      }
      final release = await connection.acquire();
      if (!connection.isClosed) {
        return _Lease(connection, release, opened: opened);
      }
      release();
      if (opened) {
        throw UtcpException(
          'The WebSocket at ${template.url} closed right after connecting.',
        );
      }
    }
  }

  Future<_Connection> _open(
    String key,
    WebSocketCallTemplate template,
    Map<String, String> headers,
  ) async {
    try {
      return _connections[key] = await _connect(key, template, headers);
    } finally {
      // Removing returns the future already being awaited by the caller.
      unawaited(_opening.remove(key));
    }
  }

  Future<_Connection> _connect(
    String key,
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
    final channel = await connectWebSocket(
      request.uri,
      headers: request.headers,
      protocol: template.protocol,
      pingInterval: template.keepAlive ? _keepAliveInterval : null,
      timeout: template.timeout,
    );
    _log.fine('Connected to ${template.url}.');
    return _Connection(key, channel);
  }

  Future<void> _drop(_Connection connection) async {
    if (_connections[connection.key] == connection) {
      _connections.remove(connection.key);
    }
    await connection.close();
  }
}

final class _Lease {
  _Lease(this.connection, this.release, {required this.opened});

  final _Connection connection;
  final void Function() release;

  /// Whether this lease opened [connection] rather than reusing it.
  final bool opened;
}

/// One pooled WebSocket. Frames are buffered as they arrive, so a close is
/// noticed even while no exchange is waiting.
final class _Connection {
  _Connection(this.key, this._channel) {
    _subscription = _channel.stream.listen(
      (frame) {
        _inbox.add(frame);
        _wake();
      },
      onError: (Object error) {
        _error ??= error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final String key;
  final WebSocketChannel _channel;
  late final StreamSubscription<Object?> _subscription;
  final _inbox = Queue<Object?>();
  Completer<void>? _waiter;
  Object? _error;
  var _done = false;
  Future<void> _tail = Future.value();
  Future<void>? _closing;

  bool get isClosed => _done || _error != null;

  /// Waits for earlier holders, then returns the function that releases
  /// the connection to the next one.
  Future<void Function()> acquire() async {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    await previous;
    return released.complete;
  }

  void send(String text) => _channel.sink.add(text);

  /// The next frame (a `String` or `List<int>`), or null once the
  /// connection has closed. Throws a [TimeoutException] at [deadline].
  Future<Object?> next(DateTime deadline) async {
    while (_inbox.isEmpty) {
      final error = _error;
      if (error != null) throw UtcpException('WebSocket error: $error');
      if (_done) return null;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException(null);
      await (_waiter ??= Completer<void>()).future.timeout(remaining);
    }
    return _inbox.removeFirst();
  }

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _done = true;
    _wake();
    await _subscription.cancel();
    await _channel.sink
        .close(status.normalClosure)
        .timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}
