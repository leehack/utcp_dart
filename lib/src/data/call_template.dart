import '../http/http_call_template.dart';
import '../json.dart';
import 'auth.dart';

typedef CallTemplateFactory = CallTemplate Function(JsonMap json);

/// Describes how to reach a manual or a tool through one transport.
///
/// Concrete types are selected by `call_template_type`. Transports added by
/// other packages register their parser with [CallTemplate.register].
abstract class CallTemplate {
  const CallTemplate({this.name, this.auth, this.allowedCommunicationProtocols});

  /// Manual name; tools registered from this manual are prefixed with it.
  final String? name;
  final Auth? auth;

  /// Transport types tools in this manual may use. When null or empty, only
  /// [callTemplateType] itself is allowed.
  final List<String>? allowedCommunicationProtocols;

  String get callTemplateType;

  JsonMap toJson();

  List<String> get effectiveAllowedProtocols {
    final allowed = allowedCommunicationProtocols;
    return allowed == null || allowed.isEmpty ? [callTemplateType] : allowed;
  }

  /// Fields shared by every call template, for use in [toJson] overrides.
  JsonMap baseJson() => {
    if (name != null) 'name': name,
    'call_template_type': callTemplateType,
    if (auth != null) 'auth': auth!.toJson(),
    if (allowedCommunicationProtocols != null)
      'allowed_communication_protocols': allowedCommunicationProtocols,
  };

  static final Map<String, CallTemplateFactory> _factories = {'http': HttpCallTemplate.fromJson};

  /// Registers a parser for a custom `call_template_type`. Returns `false`
  /// when the type is already registered and [override] is not set.
  static bool register(String type, CallTemplateFactory factory, {bool override = false}) {
    if (!override && _factories.containsKey(type)) return false;
    _factories[type] = factory;
    return true;
  }

  static CallTemplate fromJson(JsonMap json) {
    final type = json['call_template_type'];
    final factory = _factories[type];
    if (factory == null) throw FormatException('Unknown call_template_type: $type');
    return factory(json);
  }

  static Auth? authFromJson(JsonMap json, [String key = 'auth']) {
    final auth = optionalMap(json, key);
    return auth == null ? null : Auth.fromJson(auth);
  }
}
