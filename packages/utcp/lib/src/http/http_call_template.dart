import '../data/auth.dart';
import '../data/call_template.dart';
import '../json.dart';

enum HttpMethod {
  get,
  post,
  put,
  delete,
  patch;

  String get wireName => name.toUpperCase();

  static HttpMethod parse(String value) => values.firstWhere(
    (m) => m.wireName == value.toUpperCase(),
    orElse: () => throw FormatException("Unsupported http_method '$value'."),
  );
}

/// The request-shaping fields shared by the HTTP-based call templates
/// (`http`, `sse`, `streamable_http`).
///
/// Tool arguments are mapped onto the request in this order: [headerFields]
/// become headers, [bodyField] becomes the body, `{name}` placeholders in
/// [url] become path segments, and the rest become query parameters.
abstract interface class HttpRequestTemplate {
  /// Endpoint URL. Supports `{param}` path placeholders, or exactly `{url}`
  /// to take the whole URL from the `url` argument.
  String get url;
  HttpMethod get httpMethod;
  String get contentType;
  Auth? get auth;

  /// Static headers sent with every request.
  Map<String, String> get headers;

  /// Argument sent as the request body; `null` disables the body mapping.
  String? get bodyField;

  /// Arguments sent as request headers.
  List<String> get headerFields;
}

/// Calls a tool, or fetches a manual, with a single HTTP request.
class HttpCallTemplate extends CallTemplate implements HttpRequestTemplate {
  const HttpCallTemplate({
    super.name,
    required this.url,
    this.httpMethod = HttpMethod.get,
    this.contentType = 'application/json',
    super.auth,
    this.headers = const {},
    this.bodyField = 'body',
    this.headerFields = const [],
    this.authTools,
    super.allowedCommunicationProtocols,
  });

  factory HttpCallTemplate.fromJson(JsonMap json) => HttpCallTemplate(
    name: json.optString('name'),
    url: json.string('url'),
    httpMethod: HttpMethod.parse(json.optString('http_method') ?? 'GET'),
    contentType: json.optString('content_type') ?? 'application/json',
    auth: json.optAuth(),
    headers: json.optStringMap('headers') ?? const {},
    bodyField: json.containsKey('body_field')
        ? json.optString('body_field')
        : 'body',
    headerFields: json.optStringList('header_fields') ?? const [],
    authTools: json.optAuth('auth_tools'),
    allowedCommunicationProtocols: json.allowedCommunicationProtocols,
  );

  static const type = 'http';

  @override
  final String url;
  @override
  final HttpMethod httpMethod;
  @override
  final String contentType;
  @override
  final Map<String, String> headers;
  @override
  final String? bodyField;
  @override
  final List<String> headerFields;

  /// Auth applied to the tools generated from an OpenAPI specification.
  final Auth? authTools;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    'http_method': httpMethod.wireName,
    'url': url,
    'content_type': contentType,
    'headers': headers,
    'body_field': bodyField,
    'header_fields': headerFields,
    'auth_tools': ?authTools?.toJson(),
  };
}
