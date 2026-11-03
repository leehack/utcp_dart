import '../data/call_template.dart';
import '../json.dart';
import 'http_call_template.dart';

/// Streams a tool's results as Server-Sent Events.
///
/// Tool arguments are mapped onto the request like [HttpCallTemplate]. The
/// request is a `GET`, or a `POST` when [bodyField] supplies a body.
class SseCallTemplate extends CallTemplate implements HttpRequestTemplate {
  const SseCallTemplate({
    super.name,
    required this.url,
    this.eventType,
    this.reconnect = true,
    this.retryTimeout = defaultRetryTimeout,
    super.auth,
    this.headers = const {},
    this.bodyField,
    this.headerFields = const [],
    super.allowedCommunicationProtocols,
  });

  factory SseCallTemplate.fromJson(JsonMap json) => SseCallTemplate(
    name: json.optString('name'),
    url: json.string('url'),
    eventType: json.optString('event_type'),
    reconnect: json.optBool('reconnect') ?? true,
    retryTimeout: json.optMilliseconds('retry_timeout') ?? defaultRetryTimeout,
    auth: json.optAuth(),
    headers: json.optStringMap('headers') ?? const {},
    bodyField: json.optString('body_field'),
    headerFields: json.optStringList('header_fields') ?? const [],
    allowedCommunicationProtocols: json.allowedCommunicationProtocols,
  );

  static const type = 'sse';

  static const defaultRetryTimeout = Duration(seconds: 30);

  @override
  final String url;

  /// Only events of this type are yielded; `null` yields every event. An
  /// event without an `event:` field has the type `message`.
  final String? eventType;

  /// Whether a dropped stream is reopened. Calls that send a body are never
  /// re-issued, since that could run a non-idempotent tool twice.
  final bool reconnect;

  /// Wait before reconnecting, unless the server sent a `retry:` field.
  final Duration retryTimeout;

  @override
  final Map<String, String> headers;
  @override
  final String? bodyField;
  @override
  final List<String> headerFields;

  /// Not a wire field: the request is a `GET` unless it carries a body.
  @override
  HttpMethod get httpMethod => HttpMethod.get;

  /// Not a wire field: a body is sent as JSON unless [headers] set a
  /// `Content-Type`.
  @override
  String get contentType => 'application/json';

  @override
  String get callTemplateType => type;

  @override
  List<String> get endpoints => [url];

  @override
  JsonMap fieldsToJson() => {
    'url': url,
    'event_type': ?eventType,
    'reconnect': reconnect,
    'retry_timeout': retryTimeout.inMilliseconds,
    'headers': headers,
    'body_field': ?bodyField,
    'header_fields': headerFields,
  };
}
