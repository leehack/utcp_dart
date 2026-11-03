import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import '../data/auth.dart';
import '../data/tool.dart';
import '../exceptions.dart';
import '../json.dart';
import 'http_call_template.dart';
import 'security.dart';

/// An outgoing request. Header names are matched case-insensitively.
final class HttpRequestSpec {
  HttpRequestSpec(this.method, this.uri, [Map<String, String>? headers])
    : headers = {...?headers};

  HttpMethod method;
  Uri uri;
  final Map<String, String> headers;
  String? body;
  final Set<String> _sensitive = {};

  String? header(String name) => headers[_headerKey(name)];

  /// Sets [name], replacing any existing header that differs only in case.
  /// A [sensitive] header is dropped when a redirect leaves the origin.
  void setHeader(String name, String value, {bool sensitive = false}) {
    assertNoCrlf(name, 'Header name');
    assertNoCrlf(value, "Header '$name'");
    headers.remove(_headerKey(name));
    headers[name] = value;
    if (sensitive) _sensitive.add(name.toLowerCase());
  }

  void removeHeader(String name) => headers.remove(_headerKey(name));

  /// Adds [params] to the query string. `null` values are skipped, lists
  /// repeat the key, and objects are sent as JSON.
  void addQuery(Map<String, Object?> params) {
    final extra = <String, Object>{
      for (final MapEntry(:key, :value) in params.entries)
        if (value != null) key: _queryValue(value),
    };
    if (extra.isEmpty) return;
    uri = uri.replace(queryParameters: {...uri.queryParametersAll, ...extra});
  }

  String? _headerKey(String name) {
    final lower = name.toLowerCase();
    for (final key in headers.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    return null;
  }

  static Object _queryValue(Object value) => switch (value) {
    Iterable<Object?>() => [for (final v in value) '$v'],
    Map<Object?, Object?>() => jsonEncode(value),
    _ => '$value',
  };
}

/// Builds the request for a tool call: header fields, body field, path
/// parameters, then query parameters, as described in the HTTP protocol
/// specification.
HttpRequestSpec buildToolRequest(
  HttpRequestTemplate template,
  ToolArguments args,
) {
  final remaining = {...args};
  final request = HttpRequestSpec(template.httpMethod, Uri())
    ..headers.addAll(template.headers);
  for (final field in template.headerFields) {
    if (remaining.containsKey(field)) {
      request.setHeader(field, '${remaining.remove(field)}');
    }
  }
  final bodyField = template.bodyField;
  final body = bodyField == null ? null : remaining.remove(bodyField);

  final url = buildUrlWithPathParams(template.url, remaining);
  ensureSecureUrl(url, 'tool invocation');
  ensureLoopbackWasDeclared(template.url, url, 'tool invocation');
  request
    ..uri = Uri.parse(url)
    ..addQuery(remaining);

  if (body != null) {
    final contentType = request.header('content-type') ?? template.contentType;
    request
      ..setHeader('Content-Type', contentType)
      ..body = _encodeBody(body, contentType);
  }
  return request;
}

/// Substitutes `{name}` and `${name}` placeholders in [urlTemplate] with
/// URL-encoded values from [args], removing the consumed arguments.
///
/// A template of exactly `{url}` takes the whole URL from `args['url']`,
/// unencoded.
String buildUrlWithPathParams(String urlTemplate, Map<String, Object?> args) {
  if (urlTemplate == '{url}') {
    if (!args.containsKey('url')) {
      throw const UtcpException('Missing required path parameter: url');
    }
    return '${args.remove('url')}';
  }
  final names = {
    for (final m in _placeholder.allMatches(urlTemplate)) m.group(1)!,
  };
  var url = urlTemplate;
  for (final name in names) {
    if (!args.containsKey(name)) {
      throw UtcpException('Missing required path parameter: $name');
    }
    final value = Uri.encodeComponent('${args.remove(name)}');
    url = url.replaceAll('\${$name}', value).replaceAll('{$name}', value);
  }
  return url;
}

final _placeholder = RegExp(r'\$?\{([^}]+)\}');

String _encodeBody(Object body, String contentType) {
  if (body is String) return body;
  if (contentType.contains('x-www-form-urlencoded') && body is Map) {
    final form = HttpRequestSpec(HttpMethod.post, Uri())
      ..addQuery(asJsonMap(body, 'Form body'));
    return form.uri.query;
  }
  return jsonEncode(body);
}

/// A fully read response.
final class HttpResult {
  HttpResult(
    this.statusCode,
    this.reasonPhrase,
    this.headers,
    this.bodyBytes,
    this.url,
  );

  final int statusCode;
  final String? reasonPhrase;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  /// The URL that produced this response, after redirects.
  final Uri url;

  String get contentType => headers['content-type'] ?? '';

  String get text => utf8.decode(bodyBytes, allowMalformed: true);

  /// JSON content types are parsed and everything else is returned as text,
  /// per the HTTP protocol specification. YAML is parsed by content type or
  /// `.yaml`/`.yml` path. [sniffJson] also parses untyped JSON, for documents
  /// that must be structured (manuals, token responses).
  Object? decode({bool sniffJson = false}) {
    final text = this.text;
    final path = url.path;
    if (contentType.contains('yaml') ||
        path.endsWith('.yaml') ||
        path.endsWith('.yml')) {
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

  /// Throws a [UtcpHttpException] for a 4xx or 5xx status, with the
  /// server's reason truncated to [maxDetailChars] code points.
  void ensureSuccess(String context, {int maxDetailChars = 2000}) {
    if (statusCode < 400) return;
    Object? data;
    try {
      data = decode(sniffJson: true);
    } on FormatException {
      // Includes YamlException.
      data = text;
    }
    final reason = _collapse(switch (data) {
      Map<Object?, Object?>() => _errorReason(data) ?? jsonEncode(data),
      String() => data,
      _ => jsonEncode(data),
    });
    final detail = reason.isNotEmpty ? reason : _collapse(reasonPhrase ?? '');
    throw UtcpHttpException(
      'HTTP $statusCode $context: ${_truncate(detail, maxDetailChars)}',
      statusCode: statusCode,
      body: data,
    );
  }

  /// The first of `error`, `message` and `detail` that is present decides:
  /// a non-blank string is the reason; anything else falls back to the
  /// whole body.
  static String? _errorReason(Map<Object?, Object?> data) {
    for (final key in const ['error', 'message', 'detail']) {
      final value = data[key];
      if (value == null) continue;
      return value is String && value.trim().isNotEmpty ? value : null;
    }
    return null;
  }

  static String _collapse(String text) =>
      text.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]+'), ' ').trim();

  static String _truncate(String text, int maxCodePoints) {
    final runes = text.runes;
    if (runes.length <= maxCodePoints) return text;
    return '${String.fromCharCodes(runes.take(maxCodePoints))}…';
  }
}

/// A response whose body is still streaming.
final class HttpStreamedResult {
  /// [body] ends with an abort error once [abortTrigger] completes.
  HttpStreamedResult(
    http.StreamedResponse response,
    this.url, [
    Future<void>? abortTrigger,
  ]) : _response = response,
       body = abortTrigger == null
           ? response.stream
           : _abortable(response.stream, abortTrigger, url);

  final http.StreamedResponse _response;

  /// The URL that produced this response, after redirects.
  final Uri url;

  int get statusCode => _response.statusCode;

  Map<String, String> get headers => _response.headers;

  String get contentType => headers['content-type'] ?? '';

  /// The response body, single-subscription. When the request's abort
  /// trigger completes, the body ends with an [http.RequestAbortedException]
  /// and the connection is released.
  final Stream<List<int>> body;

  /// Releases the connection without reading the rest of the body. Call it
  /// only when [body] has not been listened to.
  Future<void> discard() => body.listen(null).cancel();

  // Enforced here rather than left to the http.Client so that clients
  // without abort support (MockClient, custom clients) release the
  // connection too.
  static Stream<List<int>> _abortable(
    Stream<List<int>> source,
    Future<void> abortTrigger,
    Uri url,
  ) {
    StreamSubscription<List<int>>? subscription;
    var listened = false;
    final controller = StreamController<List<int>>(sync: true);
    controller
      ..onListen = () {
        listened = true;
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            unawaited(controller.close());
          },
        );
      }
      ..onPause = (() => subscription?.pause())
      ..onResume = (() => subscription?.resume())
      ..onCancel = (() => subscription?.cancel());
    unawaited(
      abortTrigger.then((_) {
        if (!listened) {
          listened = true;
          unawaited(source.listen(null).cancel());
        }
        if (controller.isClosed) return;
        controller.addError(http.RequestAbortedException(url));
        unawaited(controller.close());
      }),
    );
    return controller.stream;
  }

  /// Reads the body of an error response and throws, or returns for a
  /// success status without consuming the body.
  Future<void> ensureSuccess(String context) async {
    if (statusCode < 400) return;
    (await read()).ensureSuccess(context);
  }

  Future<HttpResult> read() async => HttpResult(
    statusCode,
    _response.reasonPhrase,
    headers,
    await http.ByteStream(body).toBytes(),
    url,
  );
}

/// Returns the stream [build] creates, completing the abort trigger it is
/// given as soon as the listener cancels.
///
/// An `async*` body notices a cancelled listener only at its next `yield`, so
/// one waiting on a pending request or a quiet response body would keep the
/// connection open. Pass the trigger to [HttpTransport.open] instead.
Stream<T> abortOnCancel<T>(
  Stream<T> Function(Future<void> abortTrigger) build,
) {
  final abort = Completer<void>();
  StreamSubscription<T>? subscription;
  final controller = StreamController<T>(sync: true);
  controller
    ..onListen = () {
      subscription = build(abort.future).listen(
        controller.add,
        onError: controller.addError,
        onDone: () => unawaited(controller.close()),
      );
    }
    ..onPause = (() => subscription?.pause())
    ..onResume = (() => subscription?.resume())
    ..onCancel = () {
      if (!abort.isCompleted) abort.complete();
      return subscription?.cancel();
    };
  return controller.stream;
}

/// Sends HTTP requests under the UTCP security rules, shared by every
/// HTTP-based protocol.
///
/// Only HTTPS, or plain HTTP to a loopback address, is allowed. Every redirect
/// hop is re-validated, a redirect from a remote origin into loopback is
/// refused, and sensitive headers are dropped when a redirect leaves the
/// origin. OAuth2 client-credentials tokens are cached per full credential
/// configuration.
final class HttpTransport {
  /// When [client] is given, the caller keeps ownership of it.
  HttpTransport({http.Client? client, this.maxRedirects = 5})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final int maxRedirects;
  final _tokens = <String, ({String value, DateTime expiresAt})>{};
  final _pendingTokens = <String, Future<String>>{};

  /// Sends [request] and reads the whole body within [timeout].
  Future<HttpResult> send(
    HttpRequestSpec request, {
    required String context,
    required Duration timeout,
  }) => _withTimeout(
    (abort) async => (await _follow(request, context, abort)).read(),
    timeout,
    context,
  );

  /// Sends [request] and returns once the response headers arrive within
  /// [timeout]; the body is left to the caller.
  ///
  /// With an [errorContext], an error status is read within the same
  /// [timeout] and thrown as a [UtcpHttpException] naming it; without one,
  /// error responses are returned like any other. Completing [abortTrigger]
  /// cancels the request, or ends the body of a response already returned.
  Future<HttpStreamedResult> open(
    HttpRequestSpec request, {
    required String context,
    required Duration timeout,
    String? errorContext,
    Future<void>? abortTrigger,
  }) => _withTimeout(
    (abort) async {
      final response = await _follow(request, context, abort);
      if (errorContext != null) await response.ensureSuccess(errorContext);
      return response;
    },
    timeout,
    context,
    abortTrigger,
  );

  /// Adds the headers or query parameters [auth] requires.
  Future<void> authorize(
    HttpRequestSpec request,
    Auth? auth, {
    required Duration timeout,
  }) async {
    switch (auth) {
      case null:
        return;
      case ApiKeyAuth(:final apiKey, :final varName, :final location):
        if (apiKey.isEmpty) {
          throw const UtcpException('API key for ApiKeyAuth is empty.');
        }
        switch (location) {
          case ApiKeyLocation.header:
            request.setHeader(varName, apiKey, sensitive: true);
          case ApiKeyLocation.query:
            request.addQuery({varName: apiKey});
          case ApiKeyLocation.cookie:
            final existing = request.header('cookie');
            final cookie = '$varName=$apiKey';
            request.setHeader(
              'Cookie',
              existing == null ? cookie : '$existing; $cookie',
              sensitive: true,
            );
        }
      case BasicAuth(:final username, :final password):
        request.setHeader(
          'Authorization',
          _basic(username, password),
          sensitive: true,
        );
      case OAuth2Auth():
        final token = await _oauth2Token(auth, timeout);
        request.setHeader('Authorization', 'Bearer $token', sensitive: true);
      case OAuth2UserAuth(:final accessToken, :final varName, :final prefix):
        if (accessToken.isEmpty) {
          throw const UtcpException(
            'access_token for oauth2_user auth is empty. Provision it with an '
            'interactive login first.',
          );
        }
        request.setHeader(varName, '$prefix$accessToken', sensitive: true);
      default:
        throw UtcpException(
          "Auth type '${auth.authType}' is not supported over HTTP.",
        );
    }
  }

  void close() {
    _tokens.clear();
    if (_ownsClient) _client.close();
  }

  Future<String> _oauth2Token(OAuth2Auth auth, Duration timeout) async {
    ensureSecureUrl(auth.tokenUrl, 'OAuth2 token URL');
    // Keyed on the whole configuration so templates sharing a client_id but
    // not an issuer, secret or scope never receive each other's tokens.
    final key = jsonEncode([
      auth.tokenUrl,
      auth.clientId,
      auth.clientSecret,
      auth.scope ?? '',
    ]);
    final cached = _tokens[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.value;
    }
    final fetch = _pendingTokens[key] ??= _fetchOAuth2Token(auth, key, timeout);
    try {
      return await fetch;
    } finally {
      // Removing returns the future already being awaited above.
      unawaited(_pendingTokens.remove(key));
    }
  }

  Future<String> _fetchOAuth2Token(
    OAuth2Auth auth,
    String cacheKey,
    Duration timeout,
  ) async {
    final errors = <String>[];
    // Providers differ on where client credentials go: try the form body
    // first, then an HTTP Basic header.
    for (final credentialsInBody in [true, false]) {
      final request =
          HttpRequestSpec(HttpMethod.post, Uri.parse(auth.tokenUrl), {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          });
      final form = HttpRequestSpec(HttpMethod.post, Uri())
        ..addQuery({
          'grant_type': 'client_credentials',
          if (credentialsInBody) 'client_id': auth.clientId,
          if (credentialsInBody) 'client_secret': auth.clientSecret,
          'scope': auth.scope ?? '',
        });
      request.body = form.uri.query;
      if (!credentialsInBody) {
        request.setHeader(
          'Authorization',
          _basic(auth.clientId, auth.clientSecret),
          sensitive: true,
        );
      }
      try {
        final response = await send(
          request,
          context: 'OAuth2 token fetch',
          timeout: timeout,
        );
        response.ensureSuccess('fetching OAuth2 token', maxDetailChars: 200);
        final data = asJsonMap(
          response.decode(sniffJson: true),
          'OAuth2 token response',
        );
        final token = data.optString('access_token');
        if (token == null || token.isEmpty) {
          throw const FormatException('access_token not found in response.');
        }
        final expiresIn = data.optInt('expires_in');
        _tokens[cacheKey] = (
          value: token,
          expiresAt: DateTime.now().add(
            Duration(
              seconds: expiresIn != null && expiresIn > 0 ? expiresIn : 3600,
            ),
          ),
        );
        return token;
      } on UtcpException catch (e) {
        errors.add(e.message);
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }
    throw UtcpException(
      "Failed to fetch OAuth2 token for client '${auth.clientId}' after trying "
      'all methods. Details: ${errors.join('; ')}',
    );
  }

  /// Runs [action] with an abort signal that fires on timeout or when
  /// [abortTrigger] completes, so a request that outlives its caller is
  /// cancelled instead of holding its connection open.
  Future<T> _withTimeout<T>(
    Future<T> Function(Completer<void> abort) action,
    Duration limit,
    String context, [
    Future<void>? abortTrigger,
  ]) {
    final abort = Completer<void>();
    void fire() {
      if (!abort.isCompleted) abort.complete();
    }

    abortTrigger?.whenComplete(fire).ignore();
    return action(abort).timeout(
      limit,
      onTimeout: () {
        fire();
        throw UtcpException(
          'Timed out after ${limit.inMilliseconds} ms during $context.',
        );
      },
    );
  }

  Future<HttpStreamedResult> _follow(
    HttpRequestSpec request,
    String context,
    Completer<void> abort,
  ) async {
    var method = request.method;
    var uri = request.uri;
    final headers = {...request.headers};
    var body = request.body;

    for (var hop = 0; ; hop++) {
      ensureSecureUrl(uri.toString(), context);
      for (final MapEntry(:key, :value) in headers.entries) {
        assertNoCrlf(key, 'Header name');
        assertNoCrlf(value, "Header '$key'");
      }
      final outgoing =
          http.AbortableRequest(
              method.wireName,
              uri,
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers.addAll(headers);
      if (body != null) outgoing.bodyBytes = utf8.encode(body);

      final response = await _client.send(outgoing);
      if (abort.isCompleted) {
        // The client ignored the abort trigger; release the late response.
        await response.stream.listen(null).cancel();
        throw http.RequestAbortedException(uri);
      }
      final location = response.headers['location'];
      if (!_redirectStatuses.contains(response.statusCode) ||
          location == null) {
        return HttpStreamedResult(response, uri, abort.future);
      }
      await response.stream.drain<void>();
      if (hop >= maxRedirects) {
        throw UtcpException('Too many redirects during $context.');
      }

      final next = uri.resolve(location);
      ensureSecureUrl(next.toString(), context);
      if (isLoopbackHost(next.host) && !isLoopbackHost(uri.host)) {
        throw UtcpSecurityException(
          'Security error during $context: refusing to follow a redirect from '
          '"$uri" to the loopback address "$next".',
        );
      }
      if (next.origin != uri.origin) {
        headers.removeWhere((name, _) {
          final lower = name.toLowerCase();
          return request._sensitive.contains(lower) || lower == 'cookie';
        });
      }
      final status = response.statusCode;
      if (status == 303 ||
          ((status == 301 || status == 302) && method == HttpMethod.post)) {
        method = HttpMethod.get;
        body = null;
        headers.removeWhere((name, _) => name.toLowerCase() == 'content-type');
      }
      uri = next;
    }
  }

  static const _redirectStatuses = {301, 302, 303, 307, 308};

  static String _basic(String username, String password) =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';
}
