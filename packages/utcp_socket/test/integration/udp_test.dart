@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

import '../support/servers.dart';

void main() {
  late UtcpClient client;
  final protocol = UdpCommunicationProtocol();

  setUpAll(() async => client = await UtcpClient.create(protocols: [protocol]));
  tearDownAll(() => client.close());

  Future<UdpTestServer> serve(
    void Function(RawDatagramSocket socket, Datagram request) handle,
  ) async {
    final server = await UdpTestServer.start(handle);
    addTearDown(server.close);
    return server;
  }

  void reply(RawDatagramSocket socket, Datagram to, String text) =>
      socket.send(utf8.encode(text), to.address, to.port);

  UdpCallTemplate at(
    UdpTestServer server, {
    int datagrams = 1,
    String host = 'localhost',
    String? responseByteFormat = 'utf-8',
    Duration timeout = const Duration(seconds: 5),
  }) => UdpCallTemplate(
    name: 'svc',
    host: host,
    port: server.port,
    numberOfResponseDatagrams: datagrams,
    responseByteFormat: responseByteFormat,
    timeout: timeout,
  );

  test('sends the arguments and returns the answer', () async {
    final server = await serve((socket, d) => reply(socket, d, 'pong'));
    final result = await protocol.callTool(client, 't', {
      'ping': 1,
    }, at(server));
    expect(result, 'pong');
    expect(utf8.decode(server.received.single.data), '{"ping":1}');
  });

  test('concatenates the expected number of datagrams', () async {
    final server = await serve((socket, d) {
      for (final part in ['a', 'b', 'c']) {
        reply(socket, d, part);
      }
    });
    expect(
      await protocol.callTool(client, 't', const {}, at(server, datagrams: 3)),
      'abc',
    );
  });

  test('returns the datagrams that arrived when later ones never do', () async {
    final server = await serve((socket, d) => reply(socket, d, 'only'));
    final watch = Stopwatch()..start();
    expect(
      await protocol.callTool(client, 't', const {}, at(server, datagrams: 2)),
      'only',
    );
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(UdpCommunicationProtocol.followUpTimeout),
    );
  });

  test('no answer times out', () async {
    final server = await serve((_, _) {});
    await expectLater(
      protocol.callTool(
        client,
        't',
        const {},
        at(server, timeout: const Duration(milliseconds: 200)),
      ),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('zero response datagrams sends without waiting', () async {
    final server = await serve((_, _) {});
    final result = await protocol.callTool(client, 't', {
      'fire': 'forget',
    }, at(server, datagrams: 0));
    expect(result, '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(utf8.decode(server.received.single.data), '{"fire":"forget"}');
  });

  test('ignores datagrams from other addresses', () async {
    // A datagram from this host's own non-loopback address reaches the
    // client with a source address other than the 127.0.0.1 target.
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final other = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .firstOrNull;
    if (other == null) {
      markTestSkipped('No non-loopback IPv4 interface.');
      return;
    }
    final spoofer = await RawDatagramSocket.bind(other, 0);
    addTearDown(spoofer.close);
    final server = await serve((socket, d) async {
      spoofer.send(utf8.encode('spoofed'), d.address, d.port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      reply(socket, d, 'genuine');
    });
    expect(
      await protocol.callTool(
        client,
        't',
        const {},
        at(server, host: '127.0.0.1'),
      ),
      'genuine',
    );
  });

  test('raw bytes without an encoding', () async {
    final server = await serve(
      (socket, d) => socket.send([0, 255], d.address, d.port),
    );
    expect(
      await protocol.callTool(
        client,
        't',
        const {},
        at(server, responseByteFormat: null),
      ),
      [0, 255],
    );
  });

  test('discovers a manual', () async {
    final server = await serve(
      (socket, d) => reply(
        socket,
        d,
        jsonEncode({
          'utcp_version': '1.0.1',
          'tools': [
            {'name': 'read_sensor'},
          ],
        }),
      ),
    );
    final result = await protocol.registerManual(client, at(server));
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(utf8.decode(server.received.single.data), '{"type": "utcp"}');
    expect(result.manual.tools.single.name, 'read_sensor');
  });

  test('an unresolvable host fails discovery without throwing', () async {
    final result = await protocol.registerManual(
      client,
      const UdpCallTemplate(name: 'x', host: 'no-such-host.invalid', port: 9),
    );
    expect(result.success, isFalse);
  });
}
