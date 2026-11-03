import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:utcp/utcp.dart';

import 'mcp_call_template.dart';

/// The `http.Client` handed to `mcp_dart`'s streamable HTTP transport, so that
/// every MCP request goes through [HttpTransport] and its security rules:
/// HTTPS or loopback only, every redirect re-validated, and credentials
/// dropped when a redirect leaves the origin.
///
/// It also adds the server's static headers and credentials to each request,
/// which lets OAuth2 tokens be refreshed when they expire.
final class McpHttpClient extends http.BaseClient {
  McpHttpClient({
    required this.server,
    required this.auth,
    required HttpTransport connection,
    required HttpTransport credentials,
    this.ownsConnection = false,
  }) : _connection = connection,
       _credentials = credentials;

  final McpHttpServer server;

  /// Manual-level auth, used unless [server] carries its own `Authorization`.
  final Auth? auth;

  /// Whether [close] closes the connection transport.
  final bool ownsConnection;

  final HttpTransport _connection;

  /// Fetches OAuth2 tokens. It follows no redirects, so client secrets are
  /// never replayed to another endpoint.
  final HttpTransport _credentials;

  static const _context = 'MCP HTTP transport';

  /// Headers `mcp_dart` sets that carry no credentials.
  static const _protocolHeaders = {
    'accept',
    'content-type',
    'mcp-protocol-version',
    'last-event-id',
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final spec = HttpRequestSpec(HttpMethod.parse(request.method), request.url);
    for (final MapEntry(:key, :value) in request.headers.entries) {
      spec.setHeader(
        key,
        value,
        sensitive: !_protocolHeaders.contains(key.toLowerCase()),
      );
    }
    for (final MapEntry(:key, :value) in server.headers.entries) {
      spec.setHeader(key, value, sensitive: true);
    }
    await _authorize(spec);
    final body = await request.finalize().toBytes();
    if (body.isNotEmpty) spec.body = utf8.decode(body);

    final response = await _connection.open(
      spec,
      context: _context,
      timeout: server.timeout,
    );
    final isEventStream = response.contentType.toLowerCase().contains(
      'text/event-stream',
    );
    return http.StreamedResponse(
      _guard(
        response.body,
        abort: request is http.Abortable ? request.abortTrigger : null,
        idleTimeout: isEventStream ? server.sseReadTimeout : null,
        url: request.url,
      ),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  Future<void> _authorize(HttpRequestSpec spec) async {
    if (server.authToken case final token?) {
      spec.setHeader('Authorization', 'Bearer $token', sensitive: true);
      return;
    }
    final auth = this.auth;
    if (auth == null || spec.header('authorization') != null) return;
    await _credentials.authorize(spec, auth, timeout: server.timeout);
  }

  /// Forwards [body], ending it with an error when [abort] completes or when
  /// no data arrives for [idleTimeout].
  static Stream<List<int>> _guard(
    Stream<List<int>> body, {
    required Future<void>? abort,
    required Duration? idleTimeout,
    required Uri url,
  }) {
    if (abort == null && idleTimeout == null) return body;
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? idle;

    void fail(Object error) {
      idle?.cancel();
      unawaited(subscription?.cancel());
      if (controller.isClosed) return;
      controller.addError(error);
      unawaited(controller.close());
    }

    void restartIdle() {
      if (idleTimeout == null) return;
      idle?.cancel();
      idle = Timer(
        idleTimeout,
        () => fail(
          UtcpException(
            'No data from the MCP server for '
            '${idleTimeout.inMilliseconds} ms.',
          ),
        ),
      );
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = body.listen(
          (chunk) {
            restartIdle();
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            idle?.cancel();
            unawaited(controller.close());
          },
        );
        restartIdle();
        unawaited(abort?.then((_) => fail(http.RequestAbortedException(url))));
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        idle?.cancel();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  void close() {
    if (ownsConnection) _connection.close();
  }
}
