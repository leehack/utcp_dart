import '../json.dart';

typedef AuthFactory = Auth Function(JsonMap json);

/// Authentication settings attached to a call template.
///
/// Concrete types are selected by `auth_type`. Additional types can be added
/// with [Auth.register].
abstract class Auth {
  const Auth();

  String get authType;

  JsonMap toJson();

  static final Map<String, AuthFactory> _factories = {
    'api_key': ApiKeyAuth.fromJson,
    'basic': BasicAuth.fromJson,
    'oauth2': OAuth2Auth.fromJson,
    'oauth2_user': OAuth2UserAuth.fromJson,
  };

  /// Registers a parser for a custom `auth_type`. Returns `false` when the type
  /// is already registered and [override] is not set.
  static bool register(String authType, AuthFactory factory, {bool override = false}) {
    if (!override && _factories.containsKey(authType)) return false;
    _factories[authType] = factory;
    return true;
  }

  static Auth fromJson(JsonMap json) {
    final type = json['auth_type'];
    final factory = _factories[type];
    if (factory == null) throw FormatException('Unknown auth_type: $type');
    return factory(json);
  }
}

enum ApiKeyLocation { header, query, cookie }

class ApiKeyAuth extends Auth {
  const ApiKeyAuth({
    required this.apiKey,
    this.varName = 'X-Api-Key',
    this.location = ApiKeyLocation.header,
  });

  factory ApiKeyAuth.fromJson(JsonMap json) {
    final location = optionalField<String>(json, 'location') ?? 'header';
    return ApiKeyAuth(
      apiKey: requiredField<String>(json, 'api_key'),
      varName: optionalField<String>(json, 'var_name') ?? 'X-Api-Key',
      location: ApiKeyLocation.values.firstWhere(
        (l) => l.name == location,
        orElse: () => throw FormatException('Invalid api_key location: $location'),
      ),
    );
  }

  final String apiKey;

  /// Header, query parameter, or cookie name that carries the key.
  final String varName;
  final ApiKeyLocation location;

  @override
  String get authType => 'api_key';

  @override
  JsonMap toJson() => {
    'auth_type': authType,
    'api_key': apiKey,
    'var_name': varName,
    'location': location.name,
  };
}

class BasicAuth extends Auth {
  const BasicAuth({required this.username, required this.password});

  factory BasicAuth.fromJson(JsonMap json) => BasicAuth(
    username: requiredField<String>(json, 'username'),
    password: requiredField<String>(json, 'password'),
  );

  final String username;
  final String password;

  @override
  String get authType => 'basic';

  @override
  JsonMap toJson() => {'auth_type': authType, 'username': username, 'password': password};
}

/// OAuth2 client-credentials flow. Tokens are fetched and cached by the
/// communication protocol.
class OAuth2Auth extends Auth {
  const OAuth2Auth({
    required this.tokenUrl,
    required this.clientId,
    required this.clientSecret,
    this.scope,
  });

  factory OAuth2Auth.fromJson(JsonMap json) => OAuth2Auth(
    tokenUrl: requiredField<String>(json, 'token_url'),
    clientId: requiredField<String>(json, 'client_id'),
    clientSecret: requiredField<String>(json, 'client_secret'),
    scope: optionalField<String>(json, 'scope'),
  );

  final String tokenUrl;
  final String clientId;
  final String clientSecret;
  final String? scope;

  @override
  String get authType => 'oauth2';

  @override
  JsonMap toJson() => {
    'auth_type': authType,
    'token_url': tokenUrl,
    'client_id': clientId,
    'client_secret': clientSecret,
    if (scope != null) 'scope': scope,
  };
}

/// A user-delegated OAuth2 token provisioned outside UTCP (usually injected
/// through a variable such as `${MY_TOKEN}`). UTCP never runs the interactive
/// flow; the remaining fields describe it for external login tools.
class OAuth2UserAuth extends Auth {
  const OAuth2UserAuth({
    required this.accessToken,
    this.grantType,
    this.tokenEndpoint,
    this.clientId,
    this.scope,
    this.deviceAuthorizationEndpoint,
    this.authorizationEndpoint,
    this.varName,
    this.prefix,
  });

  factory OAuth2UserAuth.fromJson(JsonMap json) => OAuth2UserAuth(
    accessToken: requiredField<String>(json, 'access_token'),
    grantType: optionalField<String>(json, 'grant_type'),
    tokenEndpoint: optionalField<String>(json, 'token_endpoint'),
    clientId: optionalField<String>(json, 'client_id'),
    scope: optionalField<String>(json, 'scope'),
    deviceAuthorizationEndpoint: optionalField<String>(json, 'device_authorization_endpoint'),
    authorizationEndpoint: optionalField<String>(json, 'authorization_endpoint'),
    varName: optionalField<String>(json, 'var_name'),
    prefix: optionalField<String>(json, 'prefix'),
  );

  final String accessToken;

  /// `device_code` or `authorization_code`.
  final String? grantType;
  final String? tokenEndpoint;
  final String? clientId;
  final String? scope;
  final String? deviceAuthorizationEndpoint;
  final String? authorizationEndpoint;

  /// Header name; defaults to `Authorization`.
  final String? varName;

  /// Token prefix; defaults to `Bearer `.
  final String? prefix;

  @override
  String get authType => 'oauth2_user';

  @override
  JsonMap toJson() => {
    'auth_type': authType,
    'access_token': accessToken,
    if (grantType != null) 'grant_type': grantType,
    if (tokenEndpoint != null) 'token_endpoint': tokenEndpoint,
    if (clientId != null) 'client_id': clientId,
    if (scope != null) 'scope': scope,
    if (deviceAuthorizationEndpoint != null)
      'device_authorization_endpoint': deviceAuthorizationEndpoint,
    if (authorizationEndpoint != null) 'authorization_endpoint': authorizationEndpoint,
    if (varName != null) 'var_name': varName,
    if (prefix != null) 'prefix': prefix,
  };
}
