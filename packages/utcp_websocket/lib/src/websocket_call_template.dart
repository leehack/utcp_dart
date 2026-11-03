import 'package:utcp/utcp.dart';

/// How a text response to [WebSocketCallTemplate] is returned.
enum WebSocketResponseFormat {
  /// Parsed as JSON; text that is not JSON is returned as is.
  json,

  /// Returned as the received string.
  text,

  /// Returned as received, like [text].
  raw;

  static WebSocketResponseFormat parse(String value) =>
      values.asNameMap()[value] ??
      (throw FormatException("Invalid response_format '$value'."));
}

/// Calls a tool, or fetches a manual, over a WebSocket connection.
///
/// Connections are pooled: calls whose handshake would be identical (URL,
/// [protocol], [keepAlive], [headers], `auth` and the [headerFields]
/// values) share one connection, one exchange at a time.
class WebSocketCallTemplate extends CallTemplate {
  const WebSocketCallTemplate({
    super.name,
    required this.url,
    this.message,
    this.protocol,
    this.keepAlive = true,
    this.responseFormat,
    this.timeout = const Duration(seconds: 30),
    this.headers = const {},
    this.headerFields = const [],
    super.auth,
    super.allowedCommunicationProtocols,
  }) : assert(
         message == null || message is String || message is JsonMap,
         'message must be a String or a JsonMap',
       );

  factory WebSocketCallTemplate.fromJson(JsonMap json) {
    final message = json['message'];
    if (message != null && message is! String && message is! Map) {
      throw const FormatException(
        "Field 'message' must be a string or an object.",
      );
    }
    final format = json.optString('response_format');
    final timeout = json.optInt('timeout') ?? 30;
    if (timeout <= 0) {
      throw FormatException("Field 'timeout' must be positive, got $timeout.");
    }
    return WebSocketCallTemplate(
      name: json.optString('name'),
      url: json.string('url'),
      message: message is String ? message : json.optObject('message'),
      protocol: json.optString('protocol'),
      keepAlive: json.optBool('keep_alive') ?? true,
      responseFormat: format == null
          ? null
          : WebSocketResponseFormat.parse(format),
      timeout: Duration(seconds: timeout),
      headers: json.optStringMap('headers') ?? const {},
      headerFields: json.optStringList('header_fields') ?? const [],
      auth: json.optAuth(),
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'websocket';

  /// `wss://` anywhere, or `ws://` to a loopback address.
  final String url;

  /// The message sent for a tool call: a String or a JsonMap whose strings
  /// may contain `UTCP_ARG_<name>_UTCP_ARG` placeholders. When null, the
  /// arguments are sent as one JSON object.
  final Object? message;

  /// WebSocket subprotocol requested in the handshake.
  final String? protocol;

  /// Whether the pooled connection sends a ping every 30 seconds (VM only).
  final bool keepAlive;

  /// When null, text responses are returned as received.
  final WebSocketResponseFormat? responseFormat;

  /// Limit for connecting, for a response, and for a whole streamed call;
  /// serialized as whole seconds.
  final Duration timeout;

  /// Static handshake headers. Browsers cannot send handshake headers, so
  /// on the web this must stay empty and header-based auth is unavailable.
  final Map<String, String> headers;

  /// Arguments sent as handshake headers instead of in the message.
  final List<String> headerFields;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    'url': url,
    'message': ?message,
    'protocol': ?protocol,
    'keep_alive': keepAlive,
    'response_format': ?responseFormat?.name,
    'timeout': timeout.inSeconds,
    'headers': headers,
    'header_fields': headerFields,
  };
}
