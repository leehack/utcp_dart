import 'package:utcp/utcp.dart';

/// Reaches the tools of one or more MCP servers.
///
/// Tools are registered as `manual_name.server_name.tool_name`. With
/// [registerResourcesAsTools], each resource is also registered as a
/// `manual_name.server_name.resource_<name>` tool that reads it.
class McpCallTemplate extends CallTemplate {
  const McpCallTemplate({
    super.name,
    required this.config,
    super.auth,
    this.registerResourcesAsTools = false,
    super.allowedCommunicationProtocols,
  });

  factory McpCallTemplate.fromJson(JsonMap json) => McpCallTemplate(
    name: json.optString('name'),
    config: McpConfig.fromJson(json.object('config')),
    auth: json.optAuth(),
    registerResourcesAsTools:
        json.optBool('register_resources_as_tools') ?? false,
    allowedCommunicationProtocols: json.allowedCommunicationProtocols,
  );

  static const type = 'mcp';

  final McpConfig config;

  /// Whether MCP resources are exposed as tools that read them.
  final bool registerResourcesAsTools;

  @override
  String get callTemplateType => type;

  /// The URLs of the HTTP servers; stdio servers reach no network address.
  @override
  List<String> get endpoints => [
    for (final server in config.mcpServers.values)
      if (server is McpHttpServer) server.url,
  ];

  @override
  JsonMap fieldsToJson() => {
    'config': config.toJson(),
    'register_resources_as_tools': registerResourcesAsTools,
  };
}

/// The `config` object: named MCP servers in the format MCP hosts use.
class McpConfig {
  const McpConfig({required this.mcpServers});

  factory McpConfig.fromJson(JsonMap json) => McpConfig(
    mcpServers: {
      for (final MapEntry(key: name, value: server)
          in json.object('mcpServers').entries)
        name: McpServerConfig.fromJson(
          asJsonMap(server, "Field 'mcpServers.$name'"),
          name,
        ),
    },
  );

  final Map<String, McpServerConfig> mcpServers;

  JsonMap toJson() => {
    'mcpServers': {
      for (final MapEntry(:key, :value) in mcpServers.entries)
        key: value.toJson(),
    },
  };
}

/// How to reach one MCP server.
sealed class McpServerConfig {
  const McpServerConfig({required this.timeout});

  /// Parses a server entry. `transport`, or `type` as MCP host
  /// configuration files spell it, selects the type; without either, an
  /// entry with `command` is a stdio server and one with `url` is an HTTP
  /// server.
  factory McpServerConfig.fromJson(JsonMap json, [String name = 'server']) {
    final transport =
        json.optString('transport') ??
        json.optString('type') ??
        switch (json) {
          _ when json.containsKey('command') => McpStdioServer.transport,
          _ when json.containsKey('url') => McpHttpServer.transport,
          _ => throw FormatException(
            "MCP server '$name' needs a 'command' (stdio) or a 'url' (http).",
          ),
        };
    return switch (transport) {
      McpStdioServer.transport => McpStdioServer.fromJson(json),
      'sse' => McpHttpServer.fromJson(json, name, McpHttpProtocol.sse),
      _ when _streamableHttp.contains(transport) => McpHttpServer.fromJson(
        json,
        name,
      ),
      _ => throw FormatException(
        "Unsupported transport '$transport' for MCP server '$name'. "
        "Use 'stdio', 'http' or 'sse'.",
      ),
    };
  }

  static const _streamableHttp = {
    McpHttpServer.transport,
    'streamable-http',
    'streamable_http',
    'streamableHttp',
  };

  /// Limit for connecting and for each MCP request.
  final Duration timeout;

  JsonMap toJson();
}

/// An MCP server started as a child process and spoken to over stdio.
class McpStdioServer extends McpServerConfig {
  const McpStdioServer({
    required this.command,
    this.args = const [],
    this.env = const {},
    this.cwd,
    super.timeout = const Duration(seconds: 30),
  });

  factory McpStdioServer.fromJson(JsonMap json) => McpStdioServer(
    command: json.string('command'),
    args: json.optStringList('args') ?? const [],
    env: json.optStringMap('env') ?? const {},
    cwd: json.optString('cwd'),
    timeout: _seconds(json, 'timeout', 30),
  );

  static const transport = 'stdio';

  final String command;
  final List<String> args;

  /// Added to the parent environment of the child process.
  final Map<String, String> env;

  /// Working directory of the child process.
  final String? cwd;

  @override
  JsonMap toJson() => {
    'transport': transport,
    'command': command,
    'args': args,
    'env': env,
    'cwd': ?cwd,
    'timeout': _secondsJson(timeout),
  };
}

/// How an [McpHttpServer] is spoken to.
enum McpHttpProtocol {
  /// Streamable HTTP, falling back to [sse] when the server answers the
  /// first request with 404 or 405, as the MCP specification's backwards
  /// compatibility section describes.
  streamableHttp('http'),

  /// The deprecated HTTP+SSE transport (MCP 2024-11-05) only.
  sse('sse');

  const McpHttpProtocol(this.wireName);

  /// The `transport` value written by `toJson`.
  final String wireName;
}

/// An MCP server reached over HTTP: streamable HTTP, or legacy HTTP+SSE.
class McpHttpServer extends McpServerConfig {
  const McpHttpServer({
    required this.url,
    this.protocol = McpHttpProtocol.streamableHttp,
    this.headers = const {},
    this.authToken,
    super.timeout = const Duration(seconds: 30),
    this.sseReadTimeout = const Duration(seconds: 300),
    this.terminateOnClose = true,
    this.notificationStreamMaxRetries = 0,
  });

  factory McpHttpServer.fromJson(
    JsonMap json, [
    String name = 'server',
    McpHttpProtocol protocol = McpHttpProtocol.streamableHttp,
  ]) {
    final url = json.string('url');
    if (Uri.tryParse(url)?.scheme case 'ws' || 'wss') {
      throw FormatException(
        "MCP server '$name' has a WebSocket URL, and WebSocket MCP servers "
        'are not supported. Use its streamable HTTP or SSE endpoint.',
      );
    }
    final retries = json.optInt('notification_stream_max_retries') ?? 0;
    if (retries < 0) {
      throw const FormatException(
        "Field 'notification_stream_max_retries' must not be negative.",
      );
    }
    return McpHttpServer(
      url: url,
      protocol: protocol,
      headers: json.optStringMap('headers') ?? const {},
      authToken: json.optString('auth_token'),
      timeout: _seconds(json, 'timeout', 30),
      sseReadTimeout: _seconds(json, 'sse_read_timeout', 300),
      terminateOnClose: json.optBool('terminate_on_close') ?? true,
      notificationStreamMaxRetries: retries,
    );
  }

  static const transport = 'http';

  /// The MCP endpoint (for [McpHttpProtocol.sse], the event stream URL).
  /// HTTPS, or plain HTTP to a loopback address.
  final String url;

  final McpHttpProtocol protocol;

  /// Static headers sent with every request.
  final Map<String, String> headers;

  /// Sent as `Authorization: Bearer <token>`. Takes precedence over the
  /// manual-level `auth`.
  final String? authToken;

  /// Longest silence tolerated on a server-sent event stream.
  final Duration sseReadTimeout;

  /// Whether closing the session asks the server to end it (HTTP `DELETE`).
  final bool terminateOnClose;

  /// How often the standalone notification stream may reconnect after it
  /// drops. UTCP calls are request/response, so the default is 0.
  final int notificationStreamMaxRetries;

  /// The same server, spoken to with [protocol].
  McpHttpServer withProtocol(McpHttpProtocol protocol) => McpHttpServer(
    url: url,
    protocol: protocol,
    headers: headers,
    authToken: authToken,
    timeout: timeout,
    sseReadTimeout: sseReadTimeout,
    terminateOnClose: terminateOnClose,
    notificationStreamMaxRetries: notificationStreamMaxRetries,
  );

  @override
  JsonMap toJson() => {
    'transport': protocol.wireName,
    'url': url,
    'headers': headers,
    'auth_token': ?authToken,
    'timeout': _secondsJson(timeout),
    'sse_read_timeout': _secondsJson(sseReadTimeout),
    'terminate_on_close': terminateOnClose,
    'notification_stream_max_retries': notificationStreamMaxRetries,
  };
}

Duration _seconds(JsonMap json, String key, num fallback) {
  final seconds = json.optNum(key) ?? fallback;
  if (seconds <= 0 || !seconds.isFinite) {
    throw FormatException("Field '$key' must be a positive number of seconds.");
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

num _secondsJson(Duration duration) =>
    duration.inMicroseconds % Duration.microsecondsPerSecond == 0
    ? duration.inSeconds
    : duration.inMicroseconds / Duration.microsecondsPerSecond;
