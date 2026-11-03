import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:utcp/utcp.dart';

import 'socket_communication_protocol.dart';
import 'udp_call_template.dart';

/// The `udp` transport: one request datagram per call, answered by
/// [UdpCallTemplate.numberOfResponseDatagrams] datagrams from the target
/// host. Datagrams from other hosts are ignored. Requests are not retried.
class UdpCommunicationProtocol
    extends SocketCommunicationProtocol<UdpCallTemplate> {
  /// How long to wait for each datagram after the first, as in the Python
  /// transport.
  static const followUpTimeout = Duration(seconds: 1);

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    UdpCallTemplate.type: UdpCallTemplate.fromJson,
  };

  @override
  Future<Uint8List> exchange(UdpCallTemplate template, String request) async {
    final endpoint = '${template.host}:${template.port}';
    RawDatagramSocket? socket;
    StreamQueue<Datagram>? datagrams;
    try {
      final target = await _resolve(template.host);
      socket = await RawDatagramSocket.bind(
        target.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
      final bound = socket;
      datagrams = StreamQueue(
        bound.expand(
          (event) => event == RawSocketEvent.read ? _drain(bound) : const [],
        ),
      );
      final payload = utf8.encode(request);
      if (bound.send(payload, target, template.port) != payload.length) {
        throw UtcpException('Could not send the UDP request to $endpoint.');
      }
      final responses = BytesBuilder(copy: false);
      var received = 0;
      while (received < template.numberOfResponseDatagrams) {
        final deadline = DateTime.now().add(
          received == 0 ? template.timeout : followUpTimeout,
        );
        Datagram? datagram;
        while (datagram == null) {
          final next = await datagrams
              .take(1)
              .timeout(
                deadline.difference(DateTime.now()),
                onTimeout: () => [],
              );
          if (next.isEmpty) break;
          final candidate = next.single;
          final from = candidate.address.address;
          if (from == target.address || from == template.host) {
            datagram = candidate;
          }
        }
        if (datagram == null) {
          if (received > 0) break;
          throw UtcpException(
            'UDP request to $endpoint timed out after '
            '${template.timeout.inMilliseconds} ms.',
          );
        }
        responses.add(datagram.data);
        received++;
      }
      return responses.takeBytes();
    } on SocketException catch (e) {
      throw UtcpException('UDP communication error with $endpoint: $e');
    } finally {
      await datagrams?.cancel(immediate: true);
      socket?.close();
    }
  }

  static Iterable<Datagram> _drain(RawDatagramSocket socket) sync* {
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      yield d;
    }
  }

  /// The first IPv4 address of [host], else its first address: the Python
  /// transport speaks IPv4, and `localhost` often resolves to `::1` first.
  static Future<InternetAddress> _resolve(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal;
    final addresses = await InternetAddress.lookup(host);
    return addresses.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
  }
}
