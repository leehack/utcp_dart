import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';

/// Serves a UTCP manual and a weather endpoint on localhost, then discovers
/// and calls the tool through UtcpClient.
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://localhost:${server.port}';
  server.listen((request) async {
    final body = switch (request.uri.path) {
      '/utcp' => {
        'utcp_version': '1.0.1',
        'tools': [
          {
            'name': 'get_weather',
            'description': 'Current weather for a city',
            'tags': ['weather'],
            'inputs': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
            'tool_call_template': {
              'call_template_type': 'http',
              'url': '$base/weather/{city}',
              'auth': {'auth_type': 'api_key', 'api_key': r'${API_KEY}'},
            },
          },
        ],
      },
      _ => {
        'city': Uri.decodeComponent(request.uri.pathSegments.last),
        'temperature_c': 21,
        'authorized': request.headers.value('X-Api-Key') == 'demo-key',
      },
    };
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  });

  final client = await UtcpClient.create(
    config: UtcpClientConfig(
      // Variables are namespaced by manual name: ${API_KEY} in manual
      // "weather" resolves weather_API_KEY.
      variables: {'weather_API_KEY': 'demo-key'},
      manualCallTemplates: [
        HttpCallTemplate(name: 'weather', url: '$base/utcp'),
      ],
    ),
  );

  final tool = (await client.searchTools('weather')).first;
  print('Found ${tool.name}: ${tool.description}');
  print(await client.callTool(tool.name, {'city': 'Seoul'}));

  await client.close();
  await server.close();
}
