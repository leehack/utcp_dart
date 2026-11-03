import 'package:utcp/utcp.dart';

/// How tool arguments are turned into the request payload.
enum RequestDataFormat {
  /// The arguments as one JSON object.
  json,

  /// [SocketCallTemplate.requestDataTemplate] with every
  /// `UTCP_ARG_<name>_UTCP_ARG` placeholder replaced by that argument, or the
  /// argument values joined by spaces when there is no template.
  text;

  static RequestDataFormat parse(String value) =>
      values.asNameMap()[value] ??
      (throw FormatException("Invalid request_data_format '$value'."));
}

/// The fields the `tcp` and `udp` call templates share.
///
/// Raw sockets carry no credentials, so these templates reject `auth`.
abstract class SocketCallTemplate extends CallTemplate {
  const SocketCallTemplate({
    super.name,
    required this.host,
    required this.port,
    this.requestDataFormat = RequestDataFormat.json,
    this.requestDataTemplate,
    this.responseByteFormat = 'utf-8',
    this.timeout = const Duration(seconds: 30),
    super.allowedCommunicationProtocols,
  });

  final String host;
  final int port;
  final RequestDataFormat requestDataFormat;

  /// Used by [RequestDataFormat.text]; may contain
  /// `UTCP_ARG_<name>_UTCP_ARG` placeholders.
  final String? requestDataTemplate;

  /// Encoding used to decode the response, such as `utf-8`, `ascii` or
  /// `latin1`. When null, tool calls return the raw bytes. A response that
  /// does not decode is also returned as raw bytes.
  final String? responseByteFormat;

  /// Serialized as whole milliseconds.
  final Duration timeout;

  /// `<type>://host:port`, so the core remote-loopback rule covers the
  /// address.
  @override
  List<String> get endpoints {
    final ipv6 = host.contains(':') && !host.startsWith('[');
    return ['$callTemplateType://${ipv6 ? '[$host]' : host}:$port'];
  }

  /// The shared fields, in their wire form.
  JsonMap socketFieldsToJson() => {
    'host': host,
    'port': port,
    'request_data_format': requestDataFormat.name,
    'request_data_template': ?requestDataTemplate,
    'response_byte_format': responseByteFormat,
    'timeout': timeout.inMilliseconds,
  };
}

/// Reads the fields every [SocketCallTemplate] shares.
extension SocketCallTemplateJson on JsonMap {
  /// Throws when [json] carries `auth`, which raw sockets cannot apply.
  void rejectAuth(String type) {
    if (this['auth'] != null) {
      throw FormatException("'$type' call templates do not support auth.");
    }
  }

  int get socketPort {
    final port =
        optInt('port') ??
        (throw const FormatException("Missing required field 'port'."));
    if (port < 1 || port > 65535) {
      throw FormatException("Field 'port' must be 1-65535, got $port.");
    }
    return port;
  }

  RequestDataFormat get requestDataFormat =>
      RequestDataFormat.parse(optString('request_data_format') ?? 'json');

  /// `utf-8` when absent; an explicit null selects raw bytes.
  String? get responseByteFormat => containsKey('response_byte_format')
      ? optString('response_byte_format')
      : 'utf-8';

  Duration get socketTimeout =>
      Duration(milliseconds: positiveInt('timeout') ?? 30000);

  /// The integer at [key], which must be greater than zero when present.
  int? positiveInt(String key) {
    final value = optInt(key);
    if (value != null && value <= 0) {
      throw FormatException("Field '$key' must be positive, got $value.");
    }
    return value;
  }
}
