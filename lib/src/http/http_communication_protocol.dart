import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import '../client.dart';
import '../communication_protocol.dart';
import '../data/auth.dart';
import '../data/call_template.dart';
import '../data/utcp_manual.dart';
import '../exceptions.dart';
import '../json.dart';
import 'http_call_template.dart';
import 'security.dart';

final _log = Logger('utcp.http');

/// HTTP transport for `call_template_type: http`.
///
/// Only HTTPS, or plain HTTP to a literal loopback address, is allowed. Every
/// redirect hop is re-validated, and auth headers are dropped when a redirect
/// leaves the original origin.
class HttpCommunicationProtocol extends CommunicationProtocol {
  /// When [httpClient] is given, the caller keeps ownership of it.
  HttpCommunicationProtocol({
    http.Client? httpClient,
    this.discoveryTimeout = const Duration(seconds: 10),
    this.timeout = const Duration(seconds: 30),
    this.maxRedirects = 5,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Limit for manual discovery, including reading the response body.
  final Duration discoveryTimeout;

  /// Limit for tool calls and token requests, including reading the
  /// response body.
  final Duration timeout;
  final int maxRedirects;
  final _oauthTokens = <String, _Token>{};
  final _pendingTokens = <String, Future<String>>{};

  static HttpCallTemplate _asHttp(CallTemplate template) => template is HttpCallTemplate
      ? template
      : throw ArgumentError.value(template.callTemplateType, 'call_template_type', 'Expected http');

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = _asHttp(manualCallTemplate);
    try {
      ensureSecureUrl(template.url, 'manual discovery');
      final request = _Request(template.httpMethod, Uri.parse(template.url), {
        ...?template.headers,
      });
      await _applyAuth(template.auth, request);
      final response = await _send(request, 'manual discovery', discoveryTimeout);
      _throwIfError(response, "discovering tools from '${template.name}'", 200);
      final data = _decode(response, sniffJson: true);

      final UtcpManual manual;
      if (data is Map && data['utcp_version'] != null && data['tools'] is List) {
        manual = UtcpManual.fromJson(asJsonMap(data, 'UTCP manual'));
        rejectRemoteLoopbackToolUrls(response.url, manual, 'manual discovery');
      } else if (data is Map &&
          (data.containsKey('openapi') ||
              data.containsKey('swagger') ||
              data.containsKey('paths'))) {
        throw const UtcpException(
          'OpenAPI specifications are not supported yet; serve a UTCP manual instead.',
        );
      } else {
        throw const FormatException(
          'Response is neither a UTCP manual nor an OpenAPI specification.',
        );
      }
      return RegisterManualResult(manualCallTemplate: template, manual: manual, success: true);
    } catch (e) {
      _log.warning("Discovery from '${template.name}' failed: $e");
      return RegisterManualResult(
        manualCallTemplate: template,
        manual: const UtcpManual(tools: []),
        success: false,
        errors: [e is UtcpException ? e.message : '$e'],
      );
    }
  }

  @override
  Future<void> deregisterManual(UtcpClient caller, CallTemplate manualCallTemplate) async {}

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    Map<String, dynamic> toolArgs,
    CallTemplate toolCallTemplate,
  ) async {
    final template = _asHttp(toolCallTemplate);
    final remaining = Map<String, dynamic>.of(toolArgs);
    final headers = {...?template.headers};

    for (final field in template.headerFields ?? const <String>[]) {
      if (remaining.containsKey(field)) headers[field] = '${remaining.remove(field)}';
    }
    final bodyField = template.bodyField;
    final body = bodyField != null ? remaining.remove(bodyField) : null;

    final url = buildUrlWithPathParams(template.url, remaining);
    ensureSecureUrl(url, 'tool invocation');
    ensureLoopbackWasDeclared(template.url, url, 'tool invocation');

    final request = _Request(template.httpMethod, _withQuery(Uri.parse(url), remaining), headers);
    await _applyAuth(template.auth, request);
    if (body != null) {
      var contentTypeHeader = _findHeader(request.headers, 'content-type');
      if (contentTypeHeader == null) {
        contentTypeHeader = 'Content-Type';
        request.headers[contentTypeHeader] = template.contentType;
      }
      request.body = _encodeBody(body, request.headers[contentTypeHeader]!);
    }

    final response = await _send(request, 'tool invocation', timeout);
    _throwIfError(response, "calling tool '$toolName'", 2000);
    return _decode(response);
  }

  @override
  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    Map<String, dynamic> toolArgs,
    CallTemplate toolCallTemplate,
  ) async* {
    yield await callTool(caller, toolName, toolArgs, toolCallTemplate);
  }

  @override
  Future<void> close() async {
    _oauthTokens.clear();
    if (_ownsClient) _client.close();
  }

  Future<void> _applyAuth(Auth? auth, _Request request) async {
    switch (auth) {
      case null:
        return;
      case ApiKeyAuth():
        if (auth.apiKey.isEmpty) throw const UtcpException('API key for ApiKeyAuth is empty.');
        assertNoCrlf(auth.varName, 'ApiKeyAuth.var_name');
        switch (auth.location) {
          case ApiKeyLocation.header:
            request.setSensitiveHeader(auth.varName, auth.apiKey);
          case ApiKeyLocation.query:
            request.uri = _withQuery(request.uri, {auth.varName: auth.apiKey});
          case ApiKeyLocation.cookie:
            final existing = request.headers[_findHeader(request.headers, 'cookie')];
            final cookie = '${auth.varName}=${auth.apiKey}';
            request.setSensitiveHeader('Cookie', existing == null ? cookie : '$existing; $cookie');
        }
      case BasicAuth():
        request.setSensitiveHeader('Authorization', _basic(auth.username, auth.password));
      case OAuth2Auth():
        request.setSensitiveHeader('Authorization', 'Bearer ${await _oauth2Token(auth)}');
      case OAuth2UserAuth():
        if (auth.accessToken.isEmpty) {
          throw const UtcpException(
            'access_token for oauth2_user auth is empty. Provision it with an interactive login first.',
          );
        }
        request.setSensitiveHeader(
          auth.varName ?? 'Authorization',
          '${auth.prefix ?? 'Bearer '}${auth.accessToken}',
        );
      default:
        throw UtcpException("Auth type '${auth.authType}' is not supported by the HTTP protocol.");
    }
  }

  Future<String> _oauth2Token(OAuth2Auth auth) {
    ensureSecureUrl(auth.tokenUrl, 'OAuth2 token URL');
    // Keyed on the whole configuration so templates sharing a client_id but
    // not an issuer, secret, or scope never receive each other's tokens.
    final key = jsonEncode([auth.tokenUrl, auth.clientId, auth.clientSecret, auth.scope ?? '']);
    final cached = _oauthTokens[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return Future.value(cached.value);
    }
    return _pendingTokens[key] ??= _fetchOAuth2Token(auth, key).whenComplete(() {
      _pendingTokens.remove(key);
    });
  }

  Future<String> _fetchOAuth2Token(OAuth2Auth auth, String cacheKey) async {
    final errors = <String>[];
    // Providers differ on where client credentials go: try the form body
    // first, then an HTTP Basic header.
    for (final credentialsInBody in [true, false]) {
      final request = _Request('POST', Uri.parse(auth.tokenUrl), {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      });
      final form = {
        'grant_type': 'client_credentials',
        if (credentialsInBody) 'client_id': auth.clientId,
        if (credentialsInBody) 'client_secret': auth.clientSecret,
        'scope': auth.scope ?? '',
      };
      if (!credentialsInBody) {
        request.setSensitiveHeader('Authorization', _basic(auth.clientId, auth.clientSecret));
      }
      request.body = Uri(queryParameters: form).query;
      try {
        final response = await _send(request, 'OAuth2 token fetch', timeout);
        _throwIfError(response, 'fetching OAuth2 token', 200);
        final data = _decode(response, sniffJson: true);
        final token = data is Map ? data['access_token'] : null;
        if (token is! String || token.isEmpty) {
          throw const FormatException('access_token not found in response.');
        }
        final expiresIn = (data as Map)['expires_in'];
        _oauthTokens[cacheKey] = _Token(
          token,
          DateTime.now().add(
            Duration(seconds: expiresIn is num && expiresIn > 0 ? expiresIn.toInt() : 3600),
          ),
        );
        return token;
      } catch (e) {
        errors.add(e is UtcpException ? e.message : '$e');
      }
    }
    throw UtcpException(
      "Failed to fetch OAuth2 token for client '${auth.clientId}' after trying all methods. "
      'Details: ${errors.join('; ')}',
    );
  }

  Future<_Response> _send(_Request request, String context, Duration limit) =>
      _followRedirects(request, context).timeout(
        limit,
        onTimeout: () =>
            throw UtcpException('Timed out after ${limit.inSeconds}s during $context.'),
      );

  Future<_Response> _followRedirects(_Request request, String context) async {
    var method = request.method;
    var uri = request.uri;
    final headers = {...request.headers};
    var body = request.body;

    for (var hop = 0; ; hop++) {
      ensureSecureUrl(uri.toString(), context);
      for (final entry in headers.entries) {
        assertNoCrlf(entry.key, 'Header name');
        assertNoCrlf(entry.value, "Header '${entry.key}'");
      }
      final outgoing = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) outgoing.bodyBytes = utf8.encode(body);

      final response = await http.Response.fromStream(await _client.send(outgoing));
      final location = response.headers['location'];
      if (!_redirectStatuses.contains(response.statusCode) || location == null) {
        return _Response(response, uri);
      }
      if (hop >= maxRedirects) throw UtcpException('Too many redirects during $context.');

      final next = uri.resolve(location);
      if (isLoopbackHost(next.host) && !isLoopbackHost(uri.host)) {
        throw UtcpSecurityException(
          'Security error during $context: refusing to follow a redirect from "$uri" '
          'to the loopback address "$next".',
        );
      }
      if (next.scheme != uri.scheme || next.host != uri.host || next.port != uri.port) {
        headers.removeWhere(
          (name, _) =>
              request.sensitiveHeaders.contains(name.toLowerCase()) ||
              name.toLowerCase() == 'cookie',
        );
      }
      final status = response.statusCode;
      if (status == 303 || ((status == 301 || status == 302) && method == 'POST')) {
        method = 'GET';
        body = null;
        headers.removeWhere((name, _) => name.toLowerCase() == 'content-type');
      }
      uri = next;
    }
  }

  static const _redirectStatuses = {301, 302, 303, 307, 308};

  static void _throwIfError(_Response response, String context, int maxDetailChars) {
    final status = response.raw.statusCode;
    if (status < 400) return;
    Object? data;
    try {
      data = _decode(response, sniffJson: true);
    } on FormatException {
      data = response.text;
    }
    final reason = _collapse(switch (data) {
      Map() => _errorReason(data) ?? jsonEncode(data),
      String() => data,
      _ => jsonEncode(data),
    });
    final detail = reason.isNotEmpty ? reason : _collapse(response.raw.reasonPhrase ?? '');
    throw UtcpHttpException(
      'HTTP $status $context: ${_truncate(detail, maxDetailChars)}',
      statusCode: status,
      body: data,
    );
  }

  /// The first of `error`, `message`, `detail` that is present decides: a
  /// non-blank string is the reason, anything else means the caller should
  /// fall back to the whole body.
  static String? _errorReason(Map data) {
    for (final key in const ['error', 'message', 'detail']) {
      final value = data[key];
      if (value == null) continue;
      return value is String && value.trim().isNotEmpty ? value : null;
    }
    return null;
  }

  /// Per the HTTP protocol spec, JSON content types are parsed and everything
  /// else is returned as text. [sniffJson] also parses untyped JSON, for
  /// documents (manuals, token responses) that must be structured.
  static Object? _decode(_Response response, {bool sniffJson = false}) {
    final text = response.text;
    final contentType = response.raw.headers['content-type'] ?? '';
    final path = response.url.path;
    if (contentType.contains('yaml') || path.endsWith('.yaml') || path.endsWith('.yml')) {
      return yamlToJson(loadYaml(text));
    }
    if (text.isEmpty) return text;
    if (contentType.contains('json')) return jsonDecode(text);
    if (!sniffJson) return text;
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  static String _encodeBody(Object body, String contentType) {
    if (body is String) return body;
    if (contentType.contains('x-www-form-urlencoded') && body is Map) {
      return Uri(queryParameters: body.map((k, v) => MapEntry('$k', _queryValue(v)))).query;
    }
    return jsonEncode(body);
  }

  static Object _queryValue(Object? value) => switch (value) {
    Iterable() => [for (final v in value) '$v'],
    Map() => jsonEncode(value),
    _ => '$value',
  };

  static Uri _withQuery(Uri uri, Map<String, dynamic> params) {
    final extra = {
      for (final e in params.entries)
        if (e.value != null) e.key: _queryValue(e.value),
    };
    if (extra.isEmpty) return uri;
    final merged = <String, dynamic>{...uri.queryParametersAll, ...extra};
    return uri.replace(queryParameters: merged);
  }

  static String? _findHeader(Map<String, String> headers, String lowerName) {
    for (final name in headers.keys) {
      if (name.toLowerCase() == lowerName) return name;
    }
    return null;
  }

  static String _basic(String username, String password) =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  static String _collapse(String text) =>
      text.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]+'), ' ').trim();

  static String _truncate(String text, int maxCodePoints) {
    final runes = text.runes;
    if (runes.length <= maxCodePoints) return text;
    return '${String.fromCharCodes(runes.take(maxCodePoints))}…';
  }
}

/// Substitutes `{name}` / `${name}` placeholders in [urlTemplate] with
/// URL-encoded values from [args], removing the consumed arguments.
///
/// A template of exactly `{url}` takes the whole URL from `args['url']`
/// unencoded.
String buildUrlWithPathParams(String urlTemplate, Map<String, dynamic> args) {
  if (urlTemplate == '{url}') {
    if (!args.containsKey('url')) throw const UtcpException('Missing required path parameter: url');
    return '${args.remove('url')}';
  }
  final placeholder = RegExp(r'\$?\{([^}]+)\}');
  final names = {for (final m in placeholder.allMatches(urlTemplate)) m.group(1)!};
  var url = urlTemplate;
  for (final name in names) {
    if (!args.containsKey(name)) throw UtcpException('Missing required path parameter: $name');
    final value = Uri.encodeComponent('${args.remove(name)}');
    url = url.replaceAll('\${$name}', value).replaceAll('{$name}', value);
  }
  return url;
}

class _Request {
  _Request(this.method, this.uri, this.headers);

  final String method;
  Uri uri;
  final Map<String, String> headers;
  final sensitiveHeaders = <String>{};
  String? body;

  void setSensitiveHeader(String name, String value) {
    assertNoCrlf(name, 'Auth header name');
    assertNoCrlf(value, "Auth header '$name'");
    headers.removeWhere((existing, _) => existing.toLowerCase() == name.toLowerCase());
    headers[name] = value;
    sensitiveHeaders.add(name.toLowerCase());
  }
}

class _Response {
  _Response(this.raw, this.url);

  final http.Response raw;

  /// The URL that produced this response, after redirects.
  final Uri url;

  String get text => utf8.decode(raw.bodyBytes, allowMalformed: true);
}

class _Token {
  _Token(this.value, this.expiresAt);

  final String value;
  final DateTime expiresAt;
}
