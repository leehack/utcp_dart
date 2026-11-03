import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:utcp/utcp.dart';

const manualUrl = 'https://api.example.com/utcp';

JsonMap weatherTool({JsonMap? callTemplate}) => {
  'name': 'get_weather',
  'description': 'Get current weather for a city',
  'tags': ['weather', 'forecast'],
  'inputs': {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
    },
    'required': ['city'],
  },
  'tool_call_template':
      callTemplate ??
      {
        'call_template_type': 'http',
        'url': 'https://api.example.com/weather/{city}',
        'http_method': 'GET',
        'auth': {
          'auth_type': 'api_key',
          'api_key': r'${API_KEY}',
          'var_name': 'X-Api-Key',
        },
      },
};

JsonMap noteTool() => {
  'name': 'create_note',
  'description': 'Create a note',
  'tags': ['notes'],
  'tool_call_template': {
    'call_template_type': 'http',
    'url': 'https://api.example.com/notes',
    'http_method': 'POST',
    'header_fields': ['X-Request-Id'],
  },
};

JsonMap manualJson({List<JsonMap>? tools}) => {
  'utcp_version': '1.0.1',
  'manual_version': '1.0.0',
  'tools': tools ?? [weatherTool(), noteTool()],
};

JsonMap toolWith(String name, JsonMap callTemplate) => {
  'name': name,
  'tool_call_template': callTemplate,
};

http.Response jsonResponse(
  Object? body, [
  int status = 200,
  Map<String, String> headers = const {},
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

/// A client whose HTTP traffic goes to [handler]. The `weather-api` manual
/// at [manualUrl] is registered unless [manuals] says otherwise.
Future<UtcpClient> mockedClient(
  MockClientHandler handler, {
  Map<String, String> variables = const {},
  List<CallTemplate>? manuals,
}) => UtcpClient.create(
  config: UtcpClientConfig(
    variables: variables,
    environment: const {},
    manualCallTemplates:
        manuals ??
        [const HttpCallTemplate(name: 'weather-api', url: manualUrl)],
  ),
  protocols: [
    HttpCommunicationProtocol(
      transport: HttpTransport(client: MockClient(handler)),
    ),
  ],
);
