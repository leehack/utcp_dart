import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

/// Serves a calculator over newline-delimited TCP and a text service over
/// UDP on localhost, then discovers and calls both through UtcpClient.
Future<void> main() async {
  final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  tcp.listen((socket) {
    utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
      final request = jsonDecode(line) as Map<String, Object?>;
      final response = request['type'] == 'utcp'
          ? {
              'utcp_version': '1.0.1',
              'tools': [
                {
                  'name': 'add',
                  'description': 'Add two numbers',
                  'inputs': {
                    'type': 'object',
                    'properties': {
                      'a': {'type': 'number'},
                      'b': {'type': 'number'},
                    },
                  },
                  // No tool_call_template: the tool is called through the
                  // manual's own template.
                },
              ],
            }
          : {'sum': (request['a'] as num) + (request['b'] as num)};
      socket.write('${jsonEncode(response)}\n');
    }, onDone: socket.destroy);
  });

  final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  udp.listen((event) {
    final datagram = udp.receive();
    if (datagram == null) return;
    final request = utf8.decode(datagram.data);
    final response = request == '{"type": "utcp"}'
        ? jsonEncode({
            'utcp_version': '1.0.1',
            'tools': [
              {
                'name': 'shout',
                'tool_call_template': {
                  'call_template_type': 'udp',
                  'host': '127.0.0.1',
                  'port': udp.port,
                  'request_data_format': 'text',
                  'request_data_template': 'SHOUT UTCP_ARG_text_UTCP_ARG',
                },
              },
            ],
          })
        : request.substring('SHOUT '.length).toUpperCase();
    udp.send(utf8.encode(response), datagram.address, datagram.port);
  });

  final client = await UtcpClient.fromJson(
    {
      'manual_call_templates': [
        {
          'name': 'calc',
          'call_template_type': 'tcp',
          'host': '127.0.0.1',
          'port': tcp.port,
          'framing_strategy': 'delimiter',
          'message_delimiter': r'\n',
        },
        {
          'name': 'shout',
          'call_template_type': 'udp',
          'host': '127.0.0.1',
          'port': udp.port,
        },
      ],
    },
    protocols: [TcpCommunicationProtocol(), UdpCommunicationProtocol()],
  );

  final names = [for (final tool in await client.getTools()) tool.name];
  print('Found ${names.join(', ')}');
  print('calc.add: ${await client.callTool('calc.add', {'a': 2, 'b': 3})}');
  print(
    'shout.shout: ${await client.callTool('shout.shout', {'text': 'hello'})}',
  );

  await client.close();
  await tcp.close();
  udp.close();
}
