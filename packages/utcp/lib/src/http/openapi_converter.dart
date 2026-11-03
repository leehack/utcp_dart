import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';

import '../data/auth.dart';
import '../data/json_schema.dart';
import '../data/tool.dart';
import '../data/utcp_manual.dart';
import '../json.dart';
import 'http_call_template.dart';
import 'security.dart';

final _log = Logger('utcp.openapi');

const _operationMethods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

const _invalidNameChars = ' -.,!?\'"\\/()[]{}#@\$%^&*+=~`|;:<>';

final _absoluteUrl = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

/// Bounds the nodes produced while inlining `$ref`s into one parameter,
/// request body or response, so a spec whose references fan out cannot
/// expand exponentially. References past the limit are left in place.
const _maxResolvedNodes = 10000;

/// Converts an OpenAPI 2.0 (Swagger) or 3.x document into a [UtcpManual]
/// whose tools call the API's operations through `http` call templates.
///
/// Every operation with an `operationId` and a method [HttpMethod] supports
/// becomes a tool named after the `operationId`. Header parameters become
/// `header_fields`, the request body becomes the `body` argument, path
/// parameters stay `{name}` placeholders in the URL, and the remaining
/// parameters are sent as query parameters. Local `$ref`s are inlined;
/// cyclic, external and unresolvable references are left in place.
///
/// Security schemes become [Auth] with `${NAME_n}` placeholders (API key in
/// a header, query parameter or cookie; HTTP basic; HTTP bearer as an API
/// key; OAuth2 with a token URL). [authTools] replaces a generated auth of
/// the same type (and, for API keys, the same name and location).
class OpenApiConverter {
  /// [specUrl] is where [spec] was loaded from, after redirects: relative
  /// server and token URLs resolve against it, and a spec from a
  /// non-loopback origin may not point tools or token URLs at loopback.
  /// [baseUrl] overrides the spec's servers and lifts that loopback rule.
  /// [headers] are sent with the requests of generated tools on the spec's
  /// own origin.
  OpenApiConverter(
    this.spec, {
    this.specUrl,
    String? callTemplateName,
    this.authTools,
    this.baseUrl,
    this.headers = const {},
  }) : callTemplateName = _sanitize(
         _title(spec) ??
             callTemplateName ??
             'openapi_call_template_${_randomHex()}',
       );

  /// Whether [document] looks like an OpenAPI or Swagger specification.
  static bool isOpenApi(JsonMap document) =>
      document.containsKey('openapi') ||
      document.containsKey('swagger') ||
      document.containsKey('paths');

  final JsonMap spec;
  final Uri? specUrl;
  final Auth? authTools;
  final String? baseUrl;
  final Map<String, String> headers;

  /// Name given to the generated call templates: the spec's `info.title`,
  /// else the name passed in, with identifier-unsafe characters replaced.
  final String callTemplateName;

  int _placeholderCounter = 0;
  int _resolvedNodes = 0;

  /// Converts [spec]. Throws a [FormatException] naming the operation and
  /// field when the document is malformed, and a [UtcpSecurityException]
  /// when it breaks the HTTP security rules.
  UtcpManual convert() {
    _placeholderCounter = 0;
    final base = _resolveBaseUrl();
    final tools = <Tool>[];
    final paths = spec.optObject('paths') ?? const {};
    for (final MapEntry(key: path, value: item) in paths.entries) {
      final pathItem = asJsonMap(item, "Path '$path'");
      for (final MapEntry(key: method, value: operation) in pathItem.entries) {
        if (!_operationMethods.contains(method.toLowerCase())) continue;
        try {
          final tool = _tool(
            path,
            pathItem,
            method,
            asJsonMap(operation, 'Operation'),
            base,
          );
          if (tool != null) tools.add(tool);
        } on FormatException catch (e) {
          throw FormatException(
            "OpenAPI operation '${method.toUpperCase()} $path': ${e.message}",
          );
        }
      }
    }
    final manual = UtcpManual(tools: tools);
    final source = specUrl;
    if (source != null && !_hasBaseUrlOverride) {
      rejectRemoteLoopbackToolUrls(source, manual, 'OpenAPI conversion');
    }
    return manual;
  }

  /// Whether [url] is on the origin the spec was fetched from. The manual's
  /// static headers often carry credentials, so they are only sent to that
  /// origin, never to another host the spec names.
  bool _isSpecOrigin(String url) {
    final source = _httpSpecUrl;
    final target = Uri.tryParse(url);
    return source != null &&
        target != null &&
        target.scheme == source.scheme &&
        target.host == source.host &&
        target.port == source.port;
  }

  bool get _hasBaseUrlOverride => baseUrl?.isNotEmpty ?? false;

  /// [specUrl] when relative URLs can be resolved against it.
  Uri? get _httpSpecUrl {
    final url = specUrl;
    if (url == null || url.host.isEmpty) return null;
    return url.isScheme('http') || url.isScheme('https') ? url : null;
  }

  String _resolveBaseUrl() {
    if (_hasBaseUrlOverride) return baseUrl!;
    final servers = spec.optObjectList('servers');
    final serverUrl = servers == null || servers.isEmpty
        ? null
        : _serverUrl(servers.first);
    if (serverUrl != null) return _againstSpecUrl(serverUrl);

    // OpenAPI 2.0: host and scheme default to those serving the document.
    final basePath = spec.optString('basePath') ?? '';
    final host = spec.optString('host');
    if (host != null && host.isNotEmpty) {
      final schemes = spec.optStringList('schemes') ?? const [];
      final scheme = schemes.contains('https')
          ? 'https'
          : schemes.firstOrNull ?? _httpSpecUrl?.scheme ?? 'https';
      return '$scheme://$host$basePath';
    }
    final source = _httpSpecUrl;
    if (source != null) return '${source.origin}$basePath';
    _log.warning(
      'No server, host or spec URL in the OpenAPI document; tool URLs are '
      "relative to '/'.",
    );
    return '/';
  }

  /// `servers[0].url` with its variables' defaults filled in. A variable
  /// without a default stays a `{name}` placeholder, so it becomes a path
  /// argument of every tool.
  static String? _serverUrl(JsonMap server) {
    var url = server.optString('url');
    if (url == null || url.isEmpty) return null;
    final variables = server.optObject('variables') ?? const {};
    for (final MapEntry(key: name, value: variable) in variables.entries) {
      if (variable is! Map) continue;
      final value = variable['default'];
      if (value != null) url = url!.replaceAll('{$name}', '$value');
    }
    return url;
  }

  String _againstSpecUrl(String url) {
    final base = _httpSpecUrl;
    if (base == null || _absoluteUrl.hasMatch(url)) return url;
    // Uri.resolve would percent-encode `{name}` placeholders.
    if (!url.contains('{')) return base.resolve(url).toString();
    if (url.startsWith('//')) return '${base.scheme}:$url';
    if (url.startsWith('/')) return '${base.origin}$url';
    return '${base.resolve('.')}$url';
  }

  Tool? _tool(
    String path,
    JsonMap pathItem,
    String method,
    JsonMap operation,
    String baseUrl,
  ) {
    final operationId = operation.optString('operationId');
    if (operationId == null || operationId.isEmpty) {
      _log.fine(
        "Skipping '${method.toUpperCase()} $path': it has no operationId.",
      );
      return null;
    }
    final httpMethod = HttpMethod.values.asNameMap()[method.toLowerCase()];
    if (httpMethod == null) {
      _log.warning(
        "Skipping operation '$operationId': unsupported HTTP method "
        "'$method'.",
      );
      return null;
    }
    final summary = operation.optString('summary');
    final inputs = _inputs(pathItem, operation);
    final outputs = _outputs(operation);
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final url = '$base/${path.replaceFirst(RegExp('^/+'), '')}';
    return Tool(
      name: operationId,
      description: summary != null && summary.isNotEmpty
          ? summary
          : operation.optString('description') ?? '',
      inputs: JsonSchema(inputs.schema),
      outputs: JsonSchema(outputs),
      tags: operation.optStringList('tags') ?? const [],
      toolCallTemplate: HttpCallTemplate(
        name: callTemplateName,
        url: url,
        httpMethod: httpMethod,
        contentType: inputs.contentType,
        headers: _isSpecOrigin(url) ? headers : const {},
        bodyField: inputs.bodyField,
        headerFields: inputs.headerFields,
        auth: _auth(operation),
      ),
    );
  }

  ({
    JsonMap schema,
    List<String> headerFields,
    String? bodyField,
    String contentType,
  })
  _inputs(JsonMap pathItem, JsonMap operation) {
    final properties = <String, Object?>{};
    final required = <String>{};
    final headerFields = <String>{};
    String? bodyField;
    var contentType = 'application/json';

    for (final source in [pathItem, operation]) {
      for (final raw in source.optObjectList('parameters') ?? const []) {
        final param = _resolveObject(raw, 'Parameter');
        final name = param.optString('name');
        if (name == null || name.isEmpty) continue;
        final location = param.optString('in');
        final isRequired = param.optBool('required') ?? false;
        if (location == 'header') headerFields.add(name);

        if (location == 'body') {
          bodyField = 'body';
          final schema = param.optObject('schema') ?? const {};
          properties['body'] = _property(
            param.optString('description') ?? 'Request body',
            schema,
            [param, schema],
          );
          if (isRequired) required.add('body');
          continue;
        }

        final schema = {...?param.optObject('schema')};
        // OpenAPI 2.0 puts the type of non-body parameters on the parameter.
        for (final key in const ['type', 'items', 'enum']) {
          if (schema[key] == null && param[key] != null) {
            schema[key] = param[key];
          }
        }
        properties[name] = _property(
          param.optString('description') ?? '',
          schema,
          [param, schema],
        );
        if (isRequired) required.add(name);
      }
    }

    final rawBody = operation.optObject('requestBody');
    if (rawBody != null) {
      final body = _resolveObject(rawBody, "Field 'requestBody'");
      final content = body.optObject('content') ?? const {};
      for (final type in const [
        'application/json',
        'application/x-www-form-urlencoded',
      ]) {
        final media = content.optObject(type);
        final schema = media?.optObject('schema');
        if (schema == null) continue;
        bodyField = 'body';
        contentType = type;
        properties['body'] = _property(
          body.optString('description') ?? 'Request body',
          schema,
          [media, schema],
        );
        if (body.optBool('required') ?? false) required.add('body');
        break;
      }
    }

    return (
      schema: {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required.toList(),
      },
      headerFields: headerFields.toList(),
      // Without a body, the template default is kept rather than `null`,
      // which TypeScript's schema rejects; it stays `null` only when an
      // input named `body` must not become the request body.
      bodyField: bodyField ?? (properties.containsKey('body') ? null : 'body'),
      contentType: contentType,
    );
  }

  JsonMap _property(
    String description,
    JsonMap schema,
    List<JsonMap?> exampleSources,
  ) {
    final examples = _examples(exampleSources);
    return {
      'description': description,
      for (final MapEntry(:key, :value) in schema.entries)
        if (key != 'example' && key != 'examples') key: value,
      if (examples.isNotEmpty) 'examples': examples,
    };
  }

  JsonMap _outputs(JsonMap operation) {
    final responses = operation.optObject('responses') ?? const {};
    final raw = responses['200'] ?? responses['201'] ?? responses['default'];
    if (raw == null) return const {};
    final response = _resolveObject(raw, 'Response');

    Object? schema;
    JsonMap? media;
    final content = response.optObject('content');
    if (content != null) {
      media =
          content.optObject('application/json') ??
          content.optObject('text/plain');
      schema = media?['schema'];
      if (schema == null) {
        for (final MapEntry(:key, :value) in content.entries) {
          if (value is Map && value['schema'] != null) {
            media = asJsonMap(value, "Content '$key'");
            schema = media['schema'];
            break;
          }
        }
      }
    } else {
      schema = response['schema'];
    }
    if (schema == null) return const {};
    final json = asJsonMap(schema, 'Response schema');
    if (json.isEmpty) return const {};

    final examples = _examples([media, json]);
    return {
      'type': json['type'] ?? 'object',
      for (final key in const [
        'properties',
        'required',
        'description',
        'title',
        'items',
        'enum',
        'minimum',
        'maximum',
        'format',
      ])
        if (json[key] != null) key: json[key],
      if (examples.isNotEmpty) 'examples': examples,
    };
  }

  /// The auth of the first security requirement naming a declared scheme.
  ///
  /// An operation's own `security` replaces the global one; an empty list
  /// makes the operation public, as the OpenAPI specification defines.
  Auth? _auth(JsonMap operation) {
    final requirements =
        operation.optObjectList('security') ??
        spec.optObjectList('security') ??
        const [];
    final schemes = spec.containsKey('components')
        ? spec.optObject('components')?.optObject('securitySchemes')
        : spec.optObject('securityDefinitions');
    if (schemes == null) return null;
    for (final requirement in requirements) {
      for (final name in requirement.keys) {
        final scheme = schemes[name];
        if (scheme == null) continue;
        final generated = _authFromScheme(
          _resolveObject(scheme, "Security scheme '$name'"),
        );
        return _isCompatible(generated, authTools) ? authTools : generated;
      }
    }
    return null;
  }

  static bool _isCompatible(Auth? generated, Auth? configured) {
    if (generated == null || configured == null) return false;
    if (generated.authType != configured.authType) return false;
    if (generated is ApiKeyAuth && configured is ApiKeyAuth) {
      return generated.varName.toLowerCase() ==
              configured.varName.toLowerCase() &&
          generated.location == configured.location;
    }
    return true;
  }

  Auth? _authFromScheme(JsonMap scheme) {
    final n = _placeholderCounter;
    String placeholder(String name) => '\${${name}_$n}';
    final auth = _buildAuth(scheme, placeholder);
    if (auth != null) _placeholderCounter++;
    return auth;
  }

  Auth? _buildAuth(JsonMap scheme, String Function(String) placeholder) {
    BasicAuth basic() => BasicAuth(
      username: placeholder('USERNAME'),
      password: placeholder('PASSWORD'),
    );
    switch (scheme.optString('type')?.toLowerCase()) {
      case 'apikey':
        final location = scheme.optString('in') ?? 'header';
        return ApiKeyAuth(
          apiKey: placeholder('API_KEY'),
          varName: scheme.optString('name') ?? 'Authorization',
          location:
              ApiKeyLocation.values.asNameMap()[location] ??
              (throw FormatException(
                "Field 'in' of an apiKey security scheme must be header, "
                "query or cookie, got '$location'.",
              )),
        );
      case 'basic':
        return basic();
      case 'http':
        return switch (scheme.optString('scheme')?.toLowerCase()) {
          'basic' => basic(),
          'bearer' => ApiKeyAuth(
            apiKey: 'Bearer ${placeholder('API_KEY')}',
            varName: 'Authorization',
          ),
          _ => null,
        };
      case 'oauth2':
        final flows = scheme.optObject('flows');
        if (flows != null && flows.isNotEmpty) {
          // Client credentials first: it is the flow the HTTP transport runs.
          for (final type in const [
            'clientCredentials',
            'application',
            'authorizationCode',
            'accessCode',
          ]) {
            final flow = flows.optObject(type);
            final tokenUrl = flow?.optString('tokenUrl');
            if (flow != null && tokenUrl != null && tokenUrl.isNotEmpty) {
              return _oauth2(tokenUrl, flow, placeholder);
            }
          }
          return null;
        }
        final tokenUrl = scheme.optString('tokenUrl');
        const swagger2Flows = {
          'accessCode',
          'application',
          'clientCredentials',
        };
        if (tokenUrl != null &&
            tokenUrl.isNotEmpty &&
            swagger2Flows.contains(scheme.optString('flow'))) {
          return _oauth2(tokenUrl, scheme, placeholder);
        }
        return null;
      default:
        return null;
    }
  }

  OAuth2Auth _oauth2(
    String tokenUrl,
    JsonMap flow,
    String Function(String) placeholder,
  ) {
    final scopes = (flow.optObject('scopes') ?? const {}).keys.join(' ');
    return OAuth2Auth(
      tokenUrl: _resolveTokenUrl(tokenUrl),
      clientId: placeholder('CLIENT_ID'),
      clientSecret: placeholder('CLIENT_SECRET'),
      scope: scopes.isEmpty ? null : scopes,
    );
  }

  /// OpenAPI allows a `tokenUrl` relative to the document. It is resolved
  /// here, where the spec URL is known, so the transport's HTTPS check sees
  /// the real destination.
  String _resolveTokenUrl(String tokenUrl) {
    if (_absoluteUrl.hasMatch(tokenUrl)) {
      ensureSecureUrl(tokenUrl, 'OAuth2 tokenUrl in OpenAPI spec');
      return tokenUrl;
    }
    final base = _httpSpecUrl;
    if (base == null) return tokenUrl;
    final resolved = base.resolve(tokenUrl).toString();
    ensureSecureUrl(
      resolved,
      'OAuth2 tokenUrl in OpenAPI spec (resolved from relative URL)',
    );
    return resolved;
  }

  JsonMap _resolveObject(Object? node, String what) {
    _resolvedNodes = 0;
    return asJsonMap(_resolve(node, const {}), what);
  }

  /// A copy of [node] with local `$ref`s inlined. [resolving] holds the
  /// references being expanded above [node]; meeting one again is a cycle.
  Object? _resolve(Object? node, Set<String> resolving) {
    switch (node) {
      case Map<Object?, Object?>():
        _resolvedNodes++;
        final ref = node[r'$ref'];
        if (ref is String) {
          final target =
              ref.startsWith('#/') &&
                  !resolving.contains(ref) &&
                  _resolvedNodes <= _maxResolvedNodes
              ? _pointer(ref)
              : null;
          return target == null
              ? {r'$ref': ref}
              : _resolve(target, {...resolving, ref});
        }
        return <String, Object?>{
          for (final MapEntry(:key, :value) in node.entries)
            '$key': _resolve(value, resolving),
        };
      case List<Object?>():
        _resolvedNodes++;
        return [for (final item in node) _resolve(item, resolving)];
      default:
        return node;
    }
  }

  /// The value at the JSON pointer in the local reference [ref], or `null`.
  Object? _pointer(String ref) {
    Object? node = spec;
    for (final raw in ref.substring(2).split('/')) {
      final String part;
      try {
        part = Uri.decodeComponent(
          raw,
        ).replaceAll('~1', '/').replaceAll('~0', '~');
      } on ArgumentError {
        return null;
      }
      node = switch (node) {
        Map<Object?, Object?>() => node[part],
        List<Object?>() => switch (int.tryParse(part)) {
          final i? when i >= 0 && i < node.length => node[i],
          _ => null,
        },
        _ => null,
      };
      if (node == null) return null;
    }
    return node;
  }

  /// Examples from OpenAPI `example`, a list of `examples` (JSON Schema), or
  /// a map of Example Objects, de-duplicated in order.
  static List<Object?> _examples(List<JsonMap?> sources) {
    final merged = <Object?>[];
    final seen = <String>{};
    for (final source in sources) {
      if (source == null) continue;
      for (final example in _examplesOf(source)) {
        // YAML can produce NaN or infinity, which JSON cannot carry.
        if (!_isJsonSafe(example)) continue;
        if (seen.add(jsonEncode(_sortedKeys(example)))) merged.add(example);
      }
    }
    return merged;
  }

  static Iterable<Object?> _examplesOf(JsonMap source) sync* {
    final example = source['example'];
    if (example != null) yield example;
    switch (source['examples']) {
      case final List<Object?> list:
        yield* list;
      case final Map<Object?, Object?> named:
        for (final value in named.values) {
          if (value is Map && value.containsKey('value')) yield value['value'];
        }
    }
  }

  static bool _isJsonSafe(Object? value) => switch (value) {
    null || String() || bool() => true,
    num() => value.isFinite,
    List<Object?>() => value.every(_isJsonSafe),
    Map<Object?, Object?>() => value.values.every(_isJsonSafe),
    _ => false,
  };

  /// Makes equal objects with differently ordered keys encode identically.
  static Object? _sortedKeys(Object? value) => switch (value) {
    Map<Object?, Object?>() => {
      for (final key in value.keys.map((k) => '$k').toList()..sort())
        key: _sortedKeys(value[key]),
    },
    List<Object?>() => [for (final item in value) _sortedKeys(item)],
    _ => value,
  };

  static String? _title(JsonMap spec) {
    final title = spec.optObject('info')?.optString('title');
    return title == null || title.isEmpty ? null : title;
  }

  static String _sanitize(String name) => name.split('').map((c) {
    return _invalidNameChars.contains(c) ? '_' : c;
  }).join();

  static String _randomHex() {
    final random = Random();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }
}
