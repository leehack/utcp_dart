@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

import '../support/servers.dart';

/// The payload of one 2-byte, big-endian length-prefixed frame.
List<int> _frame(List<int> bytes) =>
    bytes.sublist(2, 2 + (bytes[0] << 8 | bytes[1]));

List<int> _framed(String text) {
  final payload = utf8.encode(text);
  return [payload.length >> 8, payload.length & 0xff, ...payload];
}

void main() {
  late TcpTestServer tcp;
  late UdpTestServer udp;
  late UtcpClient client;

  setUp(() async {
    tcp = await TcpTestServer.start((socket, input) async {
      final request = utf8.decode(_frame(await input.next));
      socket.add(
        _framed(
          request == '{"type": "utcp"}'
              ? jsonEncode({
                  'utcp_version': '1.0.1',
                  'tools': [
                    {
                      'name': 'reverse',
                      'tags': ['text'],
                      'tool_call_template': {
                        'call_template_type': 'tcp',
                        'host': r'${HOST}',
                        'port': tcp.port,
                        'framing_strategy': 'length_prefix',
                        'length_prefix_bytes': 2,
                        'request_data_format': 'text',
                        'request_data_template': 'REV UTCP_ARG_word_UTCP_ARG',
                      },
                    },
                  ],
                })
              : String.fromCharCodes(
                  request.substring(4).runes.toList().reversed,
                ),
        ),
      );
    });
    udp = await UdpTestServer.start((socket, d) {
      final request = utf8.decode(d.data);
      final response = request == '{"type": "utcp"}'
          ? utf8.encode(
              jsonEncode({
                'utcp_version': '1.0.1',
                'tools': [
                  {
                    'name': 'checksum',
                    'tool_call_template': {
                      'call_template_type': 'udp',
                      'host': '127.0.0.1',
                      'port': udp.port,
                      'response_byte_format': null,
                    },
                  },
                ],
              }),
            )
          : [request.length, ...utf8.encode('!')];
      socket.send(response, d.address, d.port);
    });
    client = await UtcpClient.fromJson(
      {
        'variables': {'text_HOST': '127.0.0.1'},
        'manual_call_templates': [
          {
            'name': 'text',
            'call_template_type': 'tcp',
            'host': 'localhost',
            'port': tcp.port,
            'framing_strategy': 'length_prefix',
            'length_prefix_bytes': 2,
          },
          {
            'name': 'sums',
            'call_template_type': 'udp',
            'host': 'localhost',
            'port': udp.port,
          },
        ],
      },
      protocols: [TcpCommunicationProtocol(), UdpCommunicationProtocol()],
      environment: const {},
    );
  });

  tearDown(() async {
    await client.close();
    await tcp.close();
    udp.close();
  });

  test('registers both manuals and calls their tools', () async {
    final names = [for (final t in await client.getTools()) t.name]..sort();
    expect(names, ['sums.checksum', 'text.reverse']);

    expect(
      await client.callTool('text.reverse', {'word': 'stressed'}),
      'desserts',
    );
    expect(
      await client.callToolStreaming('text.reverse', {'word': 'abc'}).toList(),
      ['cba'],
    );

    final checksum = await client.callTool('sums.checksum', {'x': 1});
    expect(checksum, isA<Uint8List>());
    expect(checksum, [utf8.encode('{"x":1}').length, ...utf8.encode('!')]);
  });

  test('search finds tools by tag', () async {
    final found = await client.searchTools(
      'reverse',
      anyOfTagsRequired: ['text'],
    );
    expect(found.single.name, 'text.reverse');
  });

  test('deregistering removes the tools', () async {
    expect(await client.deregisterManual('sums'), isTrue);
    expect(await client.getTool('sums.checksum'), isNull);
  });
}
