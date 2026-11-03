import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:utcp/utcp.dart';

/// A response streaming [parts]: strings are UTF-8 encoded, byte lists are
/// sent as they are, one network chunk each.
http.StreamedResponse streamedResponse(
  List<Object> parts, {
  String contentType = 'text/event-stream',
  int status = 200,
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.fromIterable([
    for (final part in parts)
      part is String ? utf8.encode(part) : List<int>.from(part as List<int>),
  ]),
  status,
  headers: {'content-type': contentType, ...headers},
);

/// A response body fed by the test, which records when the client cancels
/// it.
final class ControlledBody {
  late final controller = StreamController<List<int>>(
    onCancel: cancelled.complete,
  );
  final cancelled = Completer<void>();

  void add(String text) => controller.add(utf8.encode(text));

  http.StreamedResponse response({String contentType = 'text/event-stream'}) =>
      http.StreamedResponse(
        controller.stream,
        200,
        headers: {'content-type': contentType},
      );

  Future<void> close() => controller.close();
}

/// A client with no manuals, used as the `caller` of a protocol under test.
Future<UtcpClient> bareClient() =>
    UtcpClient.create(config: UtcpClientConfig(environment: const {}));

HttpTransport mockTransport(MockClientStreamHandler handler) =>
    HttpTransport(client: MockClient.streaming(handler));
