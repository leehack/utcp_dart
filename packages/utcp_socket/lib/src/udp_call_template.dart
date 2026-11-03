import 'package:utcp/utcp.dart';

import 'socket_call_template.dart';

/// Calls a tool, or fetches a manual, with one request datagram.
class UdpCallTemplate extends SocketCallTemplate {
  const UdpCallTemplate({
    super.name,
    required super.host,
    required super.port,
    this.numberOfResponseDatagrams = 1,
    super.requestDataFormat,
    super.requestDataTemplate,
    super.responseByteFormat,
    super.timeout,
    super.allowedCommunicationProtocols,
  });

  factory UdpCallTemplate.fromJson(JsonMap json) {
    json.rejectAuth(type);
    final datagrams = json.optInt('number_of_response_datagrams') ?? 1;
    if (datagrams < 0) {
      throw FormatException(
        "Field 'number_of_response_datagrams' must not be negative, got "
        '$datagrams.',
      );
    }
    return UdpCallTemplate(
      name: json.optString('name'),
      host: json.string('host'),
      port: json.socketPort,
      numberOfResponseDatagrams: datagrams,
      requestDataFormat: json.requestDataFormat,
      requestDataTemplate: json.optString('request_data_template'),
      responseByteFormat: json.responseByteFormat,
      timeout: json.socketTimeout,
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'udp';

  /// Datagrams to collect and concatenate into the response. Zero sends the
  /// request without waiting for an answer.
  ///
  /// The first datagram may take up to [timeout]; each later one up to a
  /// second, after which the datagrams received so far are returned.
  final int numberOfResponseDatagrams;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    ...socketFieldsToJson(),
    'number_of_response_datagrams': numberOfResponseDatagrams,
  };
}
