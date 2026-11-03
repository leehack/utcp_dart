import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

/// Serves a WebSocket provider on localhost, then discovers and calls its
/// tools through UtcpClient.
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'ws://localhost:${server.port}/ws';
  server.listen((request) async {
    final authorized = request.headers.value('X-Api-Key') == 'demo-key';
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((frame) {
      if (frame == '{"type": "utcp"}') {
        socket.add(
          jsonEncode({
            'utcp_version': utcpProtocolVersion,
            'tools': [
              {
                'name': 'greet',
                'description': 'Greet someone',
                'inputs': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string'},
                  },
                },
                'tool_call_template': {
                  'call_template_type': 'websocket',
                  'url': url,
                  'message': {
                    'action': 'greet',
                    'who': 'UTCP_ARG_name_UTCP_ARG',
                  },
                  'response_format': 'json',
                  'auth': {'auth_type': 'api_key', 'api_key': r'${API_KEY}'},
                },
              },
            ],
          }),
        );
        return;
      }
      final request = jsonDecode(frame as String) as Map<String, Object?>;
      socket.add(
        jsonEncode({
          'greeting': 'Hello, ${request['who']}!',
          'authorized': authorized,
        }),
      );
    }, onDone: socket.close);
  });

  final client = await UtcpClient.fromJson(
    {
      // Variables are namespaced by manual name: ${API_KEY} in manual
      // "greeter" resolves greeter_API_KEY.
      'variables': {'greeter_API_KEY': 'demo-key'},
      'manual_call_templates': [
        {'name': 'greeter', 'call_template_type': 'websocket', 'url': url},
      ],
    },
    protocols: [WebSocketCommunicationProtocol()],
  );

  final tool = (await client.searchTools('greet')).first;
  print('Found ${tool.name}: ${tool.description}');
  print(await client.callTool(tool.name, {'name': 'Seoul'}));

  await client.close();
  await server.close(force: true);
}
