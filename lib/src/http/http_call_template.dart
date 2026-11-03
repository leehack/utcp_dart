import '../data/auth.dart';
import '../data/call_template.dart';
import '../json.dart';

/// Calls a tool (or fetches a manual) with a single HTTP request.
///
/// Tool arguments are mapped onto the request in this order:
/// [headerFields] become headers, [bodyField] becomes the body, `{name}`
/// placeholders in [url] become path segments, and everything left becomes
/// query parameters.
class HttpCallTemplate extends CallTemplate {
  const HttpCallTemplate({
    super.name,
    required this.url,
    this.httpMethod = 'GET',
    this.contentType = 'application/json',
    super.auth,
    this.headers,
    this.bodyField = 'body',
    this.headerFields,
    this.authTools,
    super.allowedCommunicationProtocols,
  });

  factory HttpCallTemplate.fromJson(JsonMap json) {
    final method = (optionalField<String>(json, 'http_method') ?? 'GET').toUpperCase();
    if (!methods.contains(method)) throw FormatException('Unsupported http_method: $method');
    return HttpCallTemplate(
      name: optionalField<String>(json, 'name'),
      url: requiredField<String>(json, 'url'),
      httpMethod: method,
      contentType: optionalField<String>(json, 'content_type') ?? 'application/json',
      auth: CallTemplate.authFromJson(json),
      headers: optionalStringMap(json, 'headers'),
      bodyField: json.containsKey('body_field')
          ? optionalField<String>(json, 'body_field')
          : 'body',
      headerFields: optionalStringList(json, 'header_fields'),
      authTools: CallTemplate.authFromJson(json, 'auth_tools'),
      allowedCommunicationProtocols: optionalStringList(json, 'allowed_communication_protocols'),
    );
  }

  static const methods = {'GET', 'POST', 'PUT', 'DELETE', 'PATCH'};

  /// Endpoint URL. Supports `{param}` path placeholders, or exactly `{url}`
  /// to take the whole URL from the `url` argument.
  final String url;
  final String httpMethod;
  final String contentType;

  /// Static headers sent with every request.
  final Map<String, String>? headers;

  /// Argument sent as the request body; `null` disables the body mapping.
  final String? bodyField;

  /// Arguments sent as request headers.
  final List<String>? headerFields;

  /// Auth applied to tools generated from an OpenAPI spec.
  final Auth? authTools;

  @override
  String get callTemplateType => 'http';

  @override
  JsonMap toJson() => {
    ...baseJson(),
    'http_method': httpMethod,
    'url': url,
    'content_type': contentType,
    if (headers != null) 'headers': headers,
    'body_field': bodyField,
    if (headerFields != null) 'header_fields': headerFields,
    if (authTools != null) 'auth_tools': authTools!.toJson(),
  };
}
