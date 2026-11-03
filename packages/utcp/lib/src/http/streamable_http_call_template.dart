import '../data/call_template.dart';
import '../json.dart';
import 'http_call_template.dart';

/// Streams a tool's HTTP response in chunks, decoded by its Content-Type:
/// NDJSON line by line, JSON as one value, anything else as byte chunks of
/// at most [chunkSize].
///
/// Tool arguments are mapped onto the request like [HttpCallTemplate].
class StreamableHttpCallTemplate extends CallTemplate
    implements HttpRequestTemplate {
  const StreamableHttpCallTemplate({
    super.name,
    required this.url,
    this.httpMethod = HttpMethod.get,
    this.contentType = 'application/octet-stream',
    this.chunkSize = 4096,
    this.timeout = defaultTimeout,
    super.auth,
    this.headers = const {},
    this.bodyField,
    this.headerFields = const [],
    super.allowedCommunicationProtocols,
  });

  factory StreamableHttpCallTemplate.fromJson(JsonMap json) {
    final method = HttpMethod.parse(json.optString('http_method') ?? 'GET');
    if (method != HttpMethod.get && method != HttpMethod.post) {
      throw FormatException(
        "Field 'http_method' must be GET or POST, got '${method.wireName}'.",
      );
    }
    final chunkSize = json.optInt('chunk_size') ?? 4096;
    if (chunkSize <= 0) {
      throw FormatException(
        "Field 'chunk_size' must be positive, got $chunkSize.",
      );
    }
    final timeout = json.optMilliseconds('timeout') ?? defaultTimeout;
    if (timeout == Duration.zero) {
      throw const FormatException("Field 'timeout' must be positive.");
    }
    return StreamableHttpCallTemplate(
      name: json.optString('name'),
      url: json.string('url'),
      httpMethod: method,
      contentType: json.optString('content_type') ?? 'application/octet-stream',
      chunkSize: chunkSize,
      timeout: timeout,
      auth: json.optAuth(),
      headers: json.optStringMap('headers') ?? const {},
      bodyField: json.optString('body_field'),
      headerFields: json.optStringList('header_fields') ?? const [],
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'streamable_http';

  static const defaultTimeout = Duration(seconds: 60);

  @override
  final String url;

  /// `GET` or `POST`.
  @override
  final HttpMethod httpMethod;

  /// Content-Type of the request body, unless [headers] set one.
  @override
  final String contentType;

  /// Largest byte chunk yielded for binary responses.
  final int chunkSize;

  /// Limit for the whole call: token request, handshake and reading the
  /// stream.
  final Duration timeout;

  @override
  final Map<String, String> headers;
  @override
  final String? bodyField;
  @override
  final List<String> headerFields;

  @override
  String get callTemplateType => type;

  @override
  List<String> get endpoints => [url];

  @override
  JsonMap fieldsToJson() => {
    'url': url,
    'http_method': httpMethod.wireName,
    'content_type': contentType,
    'chunk_size': chunkSize,
    'timeout': timeout.inMilliseconds,
    'headers': headers,
    'body_field': ?bodyField,
    'header_fields': headerFields,
  };
}
