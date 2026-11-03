import '../http/http_call_template.dart';
import '../http/sse_call_template.dart';
import '../http/streamable_http_call_template.dart';
import '../json.dart';
import '../registry.dart';
import '../text/text_call_template.dart';
import 'auth.dart';
import 'call_template_scope.dart';

/// Describes how to reach a manual or a tool through one transport.
///
/// Concrete types are selected by `call_template_type`. The core transports
/// are built in to [CallTemplate.registry]. A `UtcpClient` parses with its
/// own protocols' parsers first, and adds the parser of a type
/// [CallTemplate.registry] does not know yet there, so code outside the
/// client can parse it too; it never replaces a parser already registered.
abstract class CallTemplate {
  const CallTemplate({
    this.name,
    this.auth,
    this.allowedCommunicationProtocols,
  });

  static final registry = TypeRegistry<CallTemplate>('call_template_type', {
    HttpCallTemplate.type: HttpCallTemplate.fromJson,
    SseCallTemplate.type: SseCallTemplate.fromJson,
    StreamableHttpCallTemplate.type: StreamableHttpCallTemplate.fromJson,
    TextCallTemplate.type: TextCallTemplate.fromJson,
  });

  /// Parses [json] with the registry of the `UtcpClient` whose discovery is
  /// running, or else with [registry].
  static CallTemplate fromJson(JsonMap json) =>
      (scopedCallTemplateRegistry ?? registry).parse(json);

  /// Manual name; tools registered from this manual are prefixed with it.
  final String? name;
  final Auth? auth;

  /// Transport types the tools of this manual may use. When null or empty,
  /// only [callTemplateType] itself is allowed (UTCP v1.1).
  final List<String>? allowedCommunicationProtocols;

  String get callTemplateType;

  /// The URLs or `scheme://host:port` addresses this template sends
  /// requests to, as written (placeholders included). A manual discovered
  /// from a remote origin may not declare loopback endpoints; transports
  /// that reach a network address override this so the rule covers them.
  List<String> get endpoints => const [];

  /// Serializes the transport-specific fields. [toJson] adds the shared ones.
  JsonMap fieldsToJson();

  JsonMap toJson() => {
    'name': ?name,
    'call_template_type': callTemplateType,
    'auth': ?auth?.toJson(),
    'allowed_communication_protocols': ?allowedCommunicationProtocols,
    ...fieldsToJson(),
  };

  List<String> get effectiveAllowedProtocols {
    final allowed = allowedCommunicationProtocols;
    return allowed == null || allowed.isEmpty ? [callTemplateType] : allowed;
  }
}

/// Reads the fields every [CallTemplate] shares.
extension CallTemplateJson on JsonMap {
  Auth? optAuth([String key = 'auth']) {
    final auth = optObject(key);
    return auth == null ? null : Auth.fromJson(auth);
  }

  List<String>? get allowedCommunicationProtocols =>
      optStringList('allowed_communication_protocols');
}
