import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:utcp/utcp.dart';

import 'mcp_call_template.dart';
import 'mcp_http_client.dart';
import 'mcp_mapping.dart';

final _log = Logger('utcp.mcp');

/// Opens the `mcp_dart` transport for one configured server.
///
/// [auth] is the manual-level auth. The default factory starts stdio servers
/// as child processes and connects to HTTP servers through [HttpTransport].
typedef McpTransportFactory =
    FutureOr<mcp.Transport> Function(
      String serverName,
      McpServerConfig server,
      Auth? auth,
    );

/// The `mcp` transport: discovers and calls the tools of MCP servers.
///
/// One MCP session per server configuration and credentials is opened on
/// first use and reused across calls. A session whose connection has closed
/// is replaced on the next request. Listing tools and resources and
/// reading a resource are retried once on a fresh session when the
/// connection drops; a tool call only when it was rejected before being
/// sent, since the server may already have run it. Sessions close when the last manual using them is
/// deregistered, and every session and child process closes in [close].
class McpCommunicationProtocol extends CommunicationProtocol {
  /// [httpClient] is used for HTTP MCP servers and OAuth2 token requests;
  /// when given, the caller keeps ownership of it. [transportFactory]
  /// replaces how servers are reached, for example with in-memory transports.
  McpCommunicationProtocol({
    http.Client? httpClient,
    McpTransportFactory? transportFactory,
  }) : _httpClient = httpClient,
       _credentials = HttpTransport(client: httpClient, maxRedirects: 0) {
    _transportFactory = transportFactory ?? _openTransport;
  }

  /// Set to `inherit` to let stdio servers write to this process's stderr.
  /// By default their stderr is drained and discarded.
  static const childStderrVariable = 'UTCP_MCP_CHILD_STDERR';

  final http.Client? _httpClient;
  final HttpTransport _credentials;
  late final McpTransportFactory _transportFactory;

  /// Live and connecting sessions, keyed by [_sessionKey].
  final _sessions = <String, Future<_Session>>{};

  /// How many registered (or registering) manuals use each session.
  final _references = <String, int>{};
  bool _closed = false;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    McpCallTemplate.type: McpCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<McpCallTemplate>(manualCallTemplate);
    final servers = template.config.mcpServers;
    if (servers.isEmpty) {
      return RegisterManualResult.failure(template, const [
        'MCP call template has no servers configured.',
      ]);
    }
    final keys = [
      for (final MapEntry(:key, :value) in servers.entries)
        _sessionKey(key, value, template.auth),
    ];
    // Held during discovery so a concurrent failure elsewhere cannot close a
    // session this registration is still using; kept only on success.
    keys.forEach(_retain);
    var keep = false;
    try {
      final errors = <String>[];
      final perServer = await Future.wait([
        for (final MapEntry(key: name, value: server) in servers.entries)
          _discover(template, name, server).catchError((Object e) {
            errors.add("Server '$name': ${_redact(_message(e), server)}");
            return const <Tool>[];
          }, test: (e) => e is UtcpException || e is FormatException),
      ]);
      if (errors.isNotEmpty) {
        _log.warning(
          "Discovery from MCP manual '${template.name}' failed: "
          '${errors.join('; ')}',
        );
      }
      keep = errors.isEmpty;
      return RegisterManualResult(
        manualCallTemplate: template,
        manual: UtcpManual(tools: [for (final tools in perServer) ...tools]),
        errors: errors,
      );
    } finally {
      if (!keep) await Future.wait(keys.map(_release));
    }
  }

  Future<List<Tool>> _discover(
    McpCallTemplate template,
    String serverName,
    McpServerConfig server,
  ) async {
    final tools = await _withSession(
      serverName,
      server,
      template.auth,
      (client) => _paginate((cursor) async {
        final page = await client.listTools(
          params: mcp.ListToolsRequest(cursor: cursor),
          options: mcp.RequestOptions(timeout: server.timeout),
        );
        return (page.tools.map<JsonMap>((t) => t.toJson()), page.nextCursor);
      }),
    );
    final result = [
      for (final tool in tools) toolFromMcp(tool, serverName, template),
    ];
    if (template.registerResourcesAsTools) {
      try {
        final resources = await _listResources(serverName, server, template);
        result.addAll([
          for (final resource in resources)
            toolFromMcpResource(resource, serverName, template),
        ]);
      } on UtcpException catch (e) {
        // Resources are optional; their absence must not fail discovery.
        // _withSession has already redacted the message.
        _log.warning(
          "Could not list resources of MCP server '$serverName': "
          '${e.message}',
        );
      }
    }
    _log.info(
      "Discovered ${result.length} tools from MCP server '$serverName'.",
    );
    return result;
  }

  Future<List<JsonMap>> _listResources(
    String serverName,
    McpServerConfig server,
    McpCallTemplate template,
  ) => _withSession(
    serverName,
    server,
    template.auth,
    (client) => _paginate((cursor) async {
      final page = await client.listResources(
        params: mcp.ListResourcesRequest(cursor: cursor),
        options: mcp.RequestOptions(timeout: server.timeout),
      );
      return (page.resources.map<JsonMap>((r) => r.toJson()), page.nextCursor);
    }),
  );

  /// Collects every page, stopping if the server repeats a cursor.
  static Future<List<JsonMap>> _paginate(
    Future<(Iterable<JsonMap>, String?)> Function(String? cursor) fetch,
  ) async {
    final items = <JsonMap>[];
    final seen = <String>{};
    String? cursor;
    do {
      final (page, next) = await fetch(cursor);
      items.addAll(page);
      cursor = next;
    } while (cursor != null && seen.add(cursor));
    return items;
  }

  @override
  Future<void> deregisterManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<McpCallTemplate>(manualCallTemplate);
    await Future.wait([
      for (final MapEntry(:key, :value) in template.config.mcpServers.entries)
        _release(_sessionKey(key, value, template.auth)),
    ]);
  }

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final template = requireCallTemplate<McpCallTemplate>(toolCallTemplate);
    final (serverName, server, name) = _route(template, toolName);
    if (template.registerResourcesAsTools &&
        name.startsWith(resourceToolPrefix)) {
      return _readResource(
        template,
        serverName,
        server,
        name.substring(resourceToolPrefix.length),
      );
    }
    final result = await _withSession(
      serverName,
      server,
      template.auth,
      (client) => client.callTool(
        mcp.CallToolRequest(name: name, arguments: arguments),
        options: mcp.RequestOptions(timeout: server.timeout),
      ),
      idempotent: false,
    );
    return toolResultValue(result.toJson());
  }

  Future<JsonMap> _readResource(
    McpCallTemplate template,
    String serverName,
    McpServerConfig server,
    String resourceName,
  ) async {
    final resources = await _listResources(serverName, server, template);
    final resource = resources.firstWhere(
      (r) => r['name'] == resourceName,
      orElse: () => throw UtcpException(
        "Resource '$resourceName' not found on MCP server '$serverName'.",
      ),
    );
    final uri = resource.string('uri');
    final result = await _withSession(
      serverName,
      server,
      template.auth,
      (client) => client.readResource(
        mcp.ReadResourceRequest(uri: uri),
        mcp.RequestOptions(timeout: server.timeout),
      ),
    );
    return {'contents': result.toJson()['contents']};
  }

  /// Splits `manual.server.tool` (or `server.tool`) into the server and the
  /// MCP tool name. The longest matching server name wins, so server names
  /// may contain dots.
  static (String, McpServerConfig, String) _route(
    McpCallTemplate template,
    String toolName,
  ) {
    final servers = template.config.mcpServers;
    final manualPrefix = '${template.name}.';
    final candidates = [
      if (template.name != null && toolName.startsWith(manualPrefix))
        toolName.substring(manualPrefix.length),
      toolName,
    ];
    for (final qualified in candidates) {
      final match = servers.keys
          .where(
            (s) =>
                qualified.startsWith('$s.') && qualified.length > s.length + 1,
          )
          .fold<String?>(
            null,
            (best, s) => best == null || s.length > best.length ? s : best,
          );
      if (match != null) {
        return (match, servers[match]!, qualified.substring(match.length + 1));
      }
    }
    throw UtcpException(
      "Tool '$toolName' does not name a server of MCP manual "
      "'${template.name}'. Expected 'manual.server.tool'.",
    );
  }

  /// Runs [operation] on the session for [server], replacing the session
  /// when its connection fails. A request that was never sent is retried
  /// once on a fresh session; any other failure only for an [idempotent]
  /// operation, since a tool call may already have run. Every
  /// [UtcpException] it throws has its message passed through [_redact].
  Future<T> _withSession<T>(
    String serverName,
    McpServerConfig server,
    Auth? auth,
    Future<T> Function(mcp.McpClient client) operation, {
    bool idempotent = true,
  }) async {
    final key = _sessionKey(serverName, server, auth);
    for (var attempt = 1; ; attempt++) {
      final pending = _session(key, serverName, server, auth);
      final _Session session;
      try {
        session = await pending;
      } on UtcpException catch (e) {
        // Such as the URL check, whose message holds the whole URL.
        throw _redacted(e, server);
      }
      _Failure failure;
      try {
        return await operation(session.client);
      } on UtcpException catch (e) {
        // Raised by HttpTransport under McpHttpClient; may name URLs.
        await _evict(key, pending);
        throw _redacted(e, server);
      } on Object catch (e) {
        final classified = _Failure.of(e);
        if (classified == null) rethrow;
        failure = classified;
      }
      if (!failure.keepSession) await _evict(key, pending);
      final message = _redact(failure.message, server);
      if (failure.retry && attempt == 1 && (idempotent || failure.unsent)) {
        _log.info(
          "MCP session for '$serverName' failed ($message); retrying on a "
          'new session.',
        );
        continue;
      }
      throw UtcpException("MCP server '$serverName': $message");
    }
  }

  Future<_Session> _session(
    String key,
    String serverName,
    McpServerConfig server,
    Auth? auth,
  ) {
    if (_closed) {
      throw const UtcpException('The MCP communication protocol is closed.');
    }
    final existing = _sessions[key];
    if (existing != null) return existing;
    final created = _connect(serverName, server, auth);
    _sessions[key] = created;
    unawaited(
      created.then(
        (session) => session.client.onclose = () => _forget(key, created),
        onError: (Object _) => _forget(key, created),
      ),
    );
    return created;
  }

  Future<_Session> _connect(
    String serverName,
    McpServerConfig server,
    Auth? auth,
  ) async {
    _log.info("Connecting to MCP server '$serverName'.");
    final transport = await _transportFactory(serverName, server, auth);
    final client = mcp.McpClient(
      const mcp.Implementation(name: 'utcp_mcp', version: '0.1.0'),
    );
    final session = _Session(client, transport, server);
    var connected = false;
    try {
      await client.connect(transport).timeout(server.timeout);
      connected = true;
    } on Object catch (e) {
      final failure = _Failure.of(e);
      if (failure == null) rethrow;
      final command = switch (server) {
        McpStdioServer(:final command) => " (command '$command')",
        McpHttpServer() => '',
      };
      throw UtcpException(
        "Could not connect to MCP server '$serverName'$command: "
        '${_redact(failure.message, server)}',
      );
    } finally {
      if (!connected) await session.close();
    }
    if (_closed) {
      await session.close();
      throw const UtcpException('The MCP communication protocol is closed.');
    }
    return session;
  }

  Future<mcp.Transport> _openTransport(
    String serverName,
    McpServerConfig server,
    Auth? auth,
  ) async {
    switch (server) {
      case McpStdioServer():
        return mcp.StdioClientTransport(
          mcp.StdioServerParameters(
            command: server.command,
            args: server.args,
            environment: server.env,
            workingDirectory: server.cwd,
            stderrMode: Platform.environment[childStderrVariable] == 'inherit'
                ? ProcessStartMode.inheritStdio
                : ProcessStartMode.normal,
            // A dead child is replaced by a fresh session, not restarted
            // behind the session's back.
            restartOnUnexpectedExit: false,
          ),
        );
      case McpHttpServer():
        ensureSecureUrl(server.url, "MCP server '$serverName'");
        final client = McpHttpClient(
          server: server,
          auth: auth,
          connection: HttpTransport(client: _httpClient),
          credentials: _credentials,
          ownsConnection: true,
        );
        // mcp_dart builds its own http.Client(); the zone makes it this one.
        return http.runWithClient(
          () => mcp.StreamableHttpClientTransport(
            Uri.parse(server.url),
            opts: mcp.StreamableHttpClientTransportOptions(
              reconnectionOptions: mcp.StreamableHttpReconnectionOptions(
                initialReconnectionDelay: 1000,
                maxReconnectionDelay: 30000,
                reconnectionDelayGrowFactor: 1.5,
                maxRetries: server.notificationStreamMaxRetries,
              ),
            ),
          ),
          () => client,
        );
    }
  }

  void _retain(String key) => _references[key] = (_references[key] ?? 0) + 1;

  Future<void> _release(String key) async {
    final remaining = (_references[key] ?? 0) - 1;
    if (remaining > 0) {
      _references[key] = remaining;
      return;
    }
    _references.remove(key);
    final session = _sessions.remove(key);
    if (session != null) await _closeQuietly(session);
  }

  Future<void> _evict(String key, Future<_Session> session) async {
    _forget(key, session);
    await _closeQuietly(session);
  }

  void _forget(String key, Future<_Session> session) {
    if (identical(_sessions[key], session)) _sessions.remove(key)?.ignore();
  }

  static Future<void> _closeQuietly(Future<_Session> session) async {
    try {
      await (await session).close();
    } on UtcpException {
      // The session never connected, so there is nothing to close.
    }
  }

  /// Identifies a session by server name, configuration and credentials, so
  /// manuals that differ in any of them never share a connection. The key
  /// carries secrets and is only used in memory.
  static String _sessionKey(
    String serverName,
    McpServerConfig server,
    Auth? auth,
  ) => jsonEncode([serverName, server.toJson(), auth?.toJson()]);

  /// Values shorter than this are left in messages: they cannot hide a
  /// usable secret, and replacing them would garble the text.
  static const _minSecretLength = 4;

  /// The first line of [message], with every configured value of [server]
  /// that may carry a secret (stdio `args` and `env`, HTTP headers, token,
  /// and URL user info and query values) masked. Later lines hold stack
  /// traces and, for a process that failed to start, its command line.
  ///
  /// The server URL as written is replaced by its scheme, host, port and
  /// path, since its escapes may differ from `Uri`'s. Elsewhere its user
  /// info and query values are masked both decoded and percent-encoded as
  /// `Uri` writes them, which is how URLs built from it quote them.
  static String _redact(String message, McpServerConfig server) {
    final url = server is McpHttpServer ? server.url : null;
    final uri = url == null ? null : Uri.tryParse(url);
    final secrets =
        [
          ...switch (server) {
            McpStdioServer(:final args, :final env) => [...args, ...env.values],
            McpHttpServer(:final headers, :final authToken) => [
              ...headers.values,
              ?authToken,
            ],
          },
          if (uri != null) ...[
            for (final part in uri.userInfo.split(':')) ...[
              part,
              Uri.decodeComponent(part),
            ],
            ...uri.queryParametersAll.values.expand((v) => v),
            for (final pair in uri.query.split('&'))
              if (pair.indexOf('=') case final i when i >= 0)
                pair.substring(i + 1),
          ],
        ].where((s) => s.length >= _minSecretLength).toList()..sort(
          (a, b) => b.length.compareTo(a.length),
        );
    var text = message.split('\n').first.trimRight();
    if (url != null && uri != null) {
      final safe = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      );
      text = text.replaceAll(url, '$safe');
    }
    for (final secret in secrets) {
      text = text.replaceAll(secret, '***');
    }
    return text;
  }

  /// [error] with [_redact] applied to its message, keeping its type.
  static UtcpException _redacted(UtcpException error, McpServerConfig server) {
    final message = _redact(error.message, server);
    if (message == error.message) return error;
    return switch (error) {
      UtcpSecurityException() => UtcpSecurityException(message),
      UtcpHttpException(:final statusCode, :final body) => UtcpHttpException(
        message,
        statusCode: statusCode,
        body: body,
      ),
      _ => UtcpException(message),
    };
  }

  static String _message(Object error) => switch (error) {
    UtcpException(:final message) => message,
    FormatException(:final message) => message,
    _ => '$error',
  };

  /// Closes every session and child process. The protocol cannot be used
  /// afterwards.
  @override
  Future<void> close() async {
    _closed = true;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _references.clear();
    await Future.wait(sessions.map(_closeQuietly));
    _credentials.close();
  }
}

final class _Failure {
  _Failure(
    this.message, {
    this.retry = false,
    this.keepSession = false,
    this.unsent = false,
  });

  static final _connectionClosed = RegExp(
    r'connection (closed|is closing)',
    caseSensitive: false,
  );

  /// How `mcp_dart`'s protocol and transports reject a request before
  /// writing any of it, on a session that is closing or closed.
  static final _rejectedBeforeSending = RegExp(
    r'^(Connection is closing\.|Not connected to a transport\.|'
    r'Cannot send message: )',
  );

  /// JSON-RPC errors are answers from a live session, except the two that
  /// `mcp_dart` raises itself when the connection closes or a request times
  /// out. Servers may also use -32000 for their own errors, so a closed
  /// connection is recognized by `mcp_dart`'s message as well.
  factory _Failure.fromMcpError(mcp.McpError error) {
    if (error.code == mcp.ErrorCode.connectionClosed.value &&
        _connectionClosed.hasMatch(error.message)) {
      return _Failure(error.message, retry: true);
    }
    if (error.code == mcp.ErrorCode.requestTimeout.value) {
      return _Failure(error.message);
    }
    return _Failure(
      '${error.message} (JSON-RPC error ${error.code})',
      keepSession: true,
    );
  }

  /// Classifies the errors `mcp_dart` and its transports raise, or returns
  /// null for anything else, which is a bug to surface unchanged.
  static _Failure? of(Object error) => switch (error) {
    mcp.McpError() => _Failure.fromMcpError(error),
    StateError(:final message) => _Failure(
      message,
      retry: true,
      unsent: _rejectedBeforeSending.hasMatch(message),
    ),
    IOException() => _Failure('$error', retry: true),
    http.ClientException(:final message) => _Failure(message, retry: true),
    TimeoutException() => _Failure('$error'),
    mcp.StreamableHttpError(:final message) => _Failure(message),
    mcp.UnauthorizedError() || mcp.StaleSessionError() => _Failure('$error'),
    FormatException(:final message) => _Failure(message, keepSession: true),
    _ => null,
  };

  final String message;
  final bool retry;
  final bool keepSession;

  /// Whether the request provably never reached the server.
  final bool unsent;
}

final class _Session {
  _Session(this.client, this.transport, this.server);

  final mcp.McpClient client;
  final mcp.Transport transport;
  final McpServerConfig server;

  Future<void> close() async {
    final transport = this.transport;
    final server = this.server;
    if (transport is mcp.StreamableHttpClientTransport &&
        server is McpHttpServer &&
        server.terminateOnClose &&
        transport.sessionId != null) {
      try {
        await transport.terminateSession().timeout(server.timeout);
      } on mcp.StreamableHttpError catch (e) {
        _log.fine('Could not terminate the MCP session: ${e.message}');
      } on Exception catch (e) {
        _log.fine('Could not terminate the MCP session: $e');
      }
    }
    client.onclose = null;
    await client.close();
    await transport.close();
  }
}
