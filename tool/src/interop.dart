/// Dart side of the cross-SDK round trip in `tool/interop/`.
library;

import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';
import 'package:utcp_file/utcp_file.dart';
import 'package:utcp_mcp/utcp_mcp.dart';
import 'package:utcp_socket/utcp_socket.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

/// Registers the call template types of every transport package, and the
/// `dotenv` variable loader, as an application using all of them would.
Future<void> registerAllTransports() async {
  final protocols = <CommunicationProtocol>[
    CliCommunicationProtocol(),
    FileCommunicationProtocol(),
    McpCommunicationProtocol(),
    TcpCommunicationProtocol(),
    UdpCommunicationProtocol(),
    WebSocketCommunicationProtocol(),
  ];
  for (final protocol in protocols) {
    for (final MapEntry(key: type, value: parse)
        in protocol.callTemplateTypes.entries) {
      CallTemplate.registry.register(type, parse);
    }
    await protocol.close();
  }
  DotEnvVariableLoader.register();
}

final Map<String, JsonMap Function(JsonMap)> _parsers = {
  'call_template': (json) => CallTemplate.fromJson(json).toJson(),
  'manual': (json) => UtcpManual.fromJson(json).toJson(),
  'config': (json) => UtcpClientConfig.fromJson(json).toJson(),
};

/// Parses every document of [input], the output of an SDK driver's
/// `serialize` command, and serializes it again. A document Dart rejects
/// carries the `error` instead of the `json`.
JsonMap roundTripDocuments(JsonMap input) => {
  'sdk': 'dart',
  'source': input.string('sdk'),
  'documents': [
    for (final document in input.objectList('documents')) _roundTrip(document),
  ],
};

JsonMap _roundTrip(JsonMap document) {
  final id = document.string('id');
  final kind = document.string('kind');
  final parse =
      _parsers[kind] ??
      (throw FormatException("Document '$id' has unknown kind '$kind'."));
  try {
    return {'id': id, 'kind': kind, 'json': parse(document.object('json'))};
  } on FormatException catch (error) {
    return {'id': id, 'kind': kind, 'error': error.message};
  }
}
