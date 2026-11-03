import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'socket_communication_protocol.dart';
import 'tcp_call_template.dart';
import 'tcp_framing.dart';

/// The `tcp` transport: one connection per request, framed per
/// [TcpCallTemplate.framingStrategy].
class TcpCommunicationProtocol
    extends SocketCommunicationProtocol<TcpCallTemplate> {
  /// Creates a protocol whose framed responses are at most [maxFrameBytes].
  TcpCommunicationProtocol({this.maxFrameBytes = 10 * 1024 * 1024});

  /// Largest `length_prefix`, `delimiter` or `fixed_length` response; a
  /// larger one fails. The reference SDKs have no limit. `stream` responses
  /// are bounded by [TcpCallTemplate.maxResponseSize] instead.
  final int maxFrameBytes;
  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    TcpCallTemplate.type: TcpCallTemplate.fromJson,
  };

  @override
  Future<Uint8List> exchange(TcpCallTemplate template, String request) async {
    final frame = encodeFrame(utf8.encode(request), template);
    final endpoint = '${template.host}:${template.port}';
    Socket? socket;
    try {
      socket = await Socket.connect(
        template.host,
        template.port,
        timeout: template.timeout,
      );
      // Write errors also complete `done`; they surface through the read.
      socket.done.ignore();
      socket.add(frame);
      await socket.flush().timeout(template.timeout);
      return await readFrame(socket, template, maxFrameBytes: maxFrameBytes);
    } on SocketException catch (e) {
      throw UtcpException('TCP communication error with $endpoint: $e');
    } on TimeoutException {
      throw UtcpException(
        'TCP request to $endpoint timed out after '
        '${template.timeout.inMilliseconds} ms.',
      );
    } finally {
      socket?.destroy();
    }
  }
}
