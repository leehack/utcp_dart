@Tags(['e2e'])
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../example/claude_tool_use.dart';
import '../support/fixtures.dart';

void main() {
  test('the Claude example answers tool calls until Claude answers', () async {
    final utcp = await mockedClient(
      (request) async => request.url.toString() == manualUrl
          ? jsonResponse(manualJson(tools: [weatherTool()]))
          : request.url.path == '/weather/Seoul'
          ? jsonResponse({'temperature_c': 21})
          : http.Response('not found', 404),
      variables: {'weather__api_API_KEY': 'k'},
    );
    addTearDown(utcp.close);

    final requests = <JsonMap>[];
    final claude = MockClient((request) async {
      requests.add(asJsonMap(jsonDecode(request.body), 'request'));
      return requests.length == 1
          ? jsonResponse({
              'stop_reason': 'tool_use',
              'content': [
                {'type': 'thinking', 'thinking': '', 'signature': 's'},
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'weather_api__get_weather',
                  'input': {'city': 'Seoul'},
                },
                {
                  'type': 'tool_use',
                  'id': 'toolu_2',
                  'name': 'missing__tool',
                  'input': <String, Object?>{},
                },
              ],
            })
          : jsonResponse({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'It is 21°C in Seoul.'},
              ],
            });
    });

    final answer = await runToolLoop(claude, 'key', utcp, 'Weather in Seoul?');

    expect(answer, 'It is 21°C in Seoul.');
    expect(requests.first['tools'], [
      containsPair('name', 'weather_api__get_weather'),
    ]);
    final messages = requests.last.objectList('messages');
    expect(messages, hasLength(3));
    expect(
      messages[1].objectList('content').first,
      containsPair('type', 'thinking'),
    );
    final results = messages[2].objectList('content');
    expect(results, hasLength(2));
    expect(results[0], {
      'type': 'tool_result',
      'tool_use_id': 'toolu_1',
      'content': '{"temperature_c":21}',
    });
    expect(results[1], containsPair('is_error', true));
  });
}
