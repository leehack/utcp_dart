import '../json.dart';
import '../registry.dart';

/// Authentication settings attached to a call template.
///
/// Concrete types are selected by `auth_type`. Additional types can be added
/// to [Auth.registry].
abstract class Auth {
  const Auth();

  static final registry = TypeRegistry<Auth>('auth_type', {
    ApiKeyAuth.type: ApiKeyAuth.fromJson,
    BasicAuth.type: BasicAuth.fromJson,
    OAuth2Auth.type: OAuth2Auth.fromJson,
    OAuth2UserAuth.type: OAuth2UserAuth.fromJson,
  });

  static Auth fromJson(JsonMap json) => registry.parse(json);

  String get authType;

  JsonMap toJson();
}

enum ApiKeyLocation { header, query, cookie }

class ApiKeyAuth extends Auth {
  const ApiKeyAuth({
    required this.apiKey,
    this.varName = 'X-Api-Key',
    this.location = ApiKeyLocation.header,
  });

  factory ApiKeyAuth.fromJson(JsonMap json) {
    final location = json.optString('location') ?? ApiKeyLocation.header.name;
    return ApiKeyAuth(
      apiKey: json.string('api_key'),
      varName: json.optString('var_name') ?? 'X-Api-Key',
      location:
          ApiKeyLocation.values.asNameMap()[location] ??
          (throw FormatException("Invalid api_key location '$location'.")),
    );
  }

  static const type = 'api_key';

  final String apiKey;

  /// Header, query parameter, or cookie name that carries the key.
  final String varName;
  final ApiKeyLocation location;

  @override
  String get authType => type;

  @override
  JsonMap toJson() => {
    'auth_type': type,
    'api_key': apiKey,
    'var_name': varName,
    'location': location.name,
  };
}

class BasicAuth extends Auth {
  const BasicAuth({required this.username, required this.password});

  factory BasicAuth.fromJson(JsonMap json) => BasicAuth(
    username: json.string('username'),
    password: json.string('password'),
  );

  static const type = 'basic';

  final String username;
  final String password;

  @override
  String get authType => type;

  @override
  JsonMap toJson() => {
    'auth_type': type,
    'username': username,
    'password': password,
  };
}

/// OAuth2 client-credentials flow. Tokens are fetched and cached by the
/// transport.
class OAuth2Auth extends Auth {
  const OAuth2Auth({
    required this.tokenUrl,
    required this.clientId,
    required this.clientSecret,
    this.scope,
  });

  factory OAuth2Auth.fromJson(JsonMap json) => OAuth2Auth(
    tokenUrl: json.string('token_url'),
    clientId: json.string('client_id'),
    clientSecret: json.string('client_secret'),
    scope: json.optString('scope'),
  );

  static const type = 'oauth2';

  final String tokenUrl;
  final String clientId;
  final String clientSecret;
  final String? scope;

  @override
  String get authType => type;

  @override
  JsonMap toJson() => {
    'auth_type': type,
    'token_url': tokenUrl,
    'client_id': clientId,
    'client_secret': clientSecret,
    'scope': ?scope,
  };
}

enum OAuth2UserGrantType {
  deviceCode('device_code'),
  authorizationCode('authorization_code');

  const OAuth2UserGrantType(this.wireName);

  final String wireName;

  static OAuth2UserGrantType parse(String value) => values.firstWhere(
    (t) => t.wireName == value,
    orElse: () => throw FormatException("Invalid grant_type '$value'."),
  );
}

/// A user-delegated OAuth2 token provisioned outside UTCP, usually injected
/// through a variable such as `${MY_TOKEN}`. UTCP never runs the interactive
/// flow; the other fields describe it for external login tools.
class OAuth2UserAuth extends Auth {
  const OAuth2UserAuth({
    required this.accessToken,
    this.grantType,
    this.tokenEndpoint,
    this.clientId,
    this.scope,
    this.deviceAuthorizationEndpoint,
    this.authorizationEndpoint,
    this.varName = 'Authorization',
    this.prefix = 'Bearer ',
  });

  factory OAuth2UserAuth.fromJson(JsonMap json) {
    final grantType = json.optString('grant_type');
    return OAuth2UserAuth(
      accessToken: json.string('access_token'),
      grantType: grantType == null
          ? null
          : OAuth2UserGrantType.parse(grantType),
      tokenEndpoint: json.optString('token_endpoint'),
      clientId: json.optString('client_id'),
      scope: json.optString('scope'),
      deviceAuthorizationEndpoint: json.optString(
        'device_authorization_endpoint',
      ),
      authorizationEndpoint: json.optString('authorization_endpoint'),
      varName: json.optString('var_name') ?? 'Authorization',
      prefix: json.optString('prefix') ?? 'Bearer ',
    );
  }

  static const type = 'oauth2_user';

  final String accessToken;
  final OAuth2UserGrantType? grantType;
  final String? tokenEndpoint;
  final String? clientId;
  final String? scope;
  final String? deviceAuthorizationEndpoint;
  final String? authorizationEndpoint;

  /// Header that carries the token.
  final String varName;

  /// Prepended to the token in [varName].
  final String prefix;

  @override
  String get authType => type;

  @override
  JsonMap toJson() => {
    'auth_type': type,
    'access_token': accessToken,
    'grant_type': ?grantType?.wireName,
    'token_endpoint': ?tokenEndpoint,
    'client_id': ?clientId,
    'scope': ?scope,
    'device_authorization_endpoint': ?deviceAuthorizationEndpoint,
    'authorization_endpoint': ?authorizationEndpoint,
    'var_name': varName,
    'prefix': prefix,
  };
}
