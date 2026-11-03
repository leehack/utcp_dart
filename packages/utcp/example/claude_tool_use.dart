import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:utcp/utcp.dart';

/// Gives UTCP tools to Claude through the Messages API and runs the
/// tool-use loop: Claude picks a tool, UtcpClient calls it, and the result
/// goes back to Claude until it answers.
///
/// Run with `ANTHROPIC_API_KEY` set:
///
/// ```sh
/// dart run example/claude_tool_use.dart "What's the weather in Seoul?"
/// ```
Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set ANTHROPIC_API_KEY to run this example.');
    exitCode = 64;
    return;
  }
  final server = await _serveWeatherTool();
  final utcp = await UtcpClient.create(
    config: UtcpClientConfig(
      manualCallTemplates: [
        HttpCallTemplate(
          name: 'weather',
          url: 'http://localhost:${server.port}/utcp',
        ),
      ],
    ),
  );
  final claude = http.Client();
  try {
    final answer = await runToolLoop(
      claude,
      apiKey,
      utcp,
      args.isEmpty ? "What's the weather in Seoul?" : args.join(' '),
    );
    print(answer);
  } finally {
    claude.close();
    await utcp.close();
    await server.close();
  }
}

/// Sends [prompt] with every UTCP tool and answers Claude's tool calls until
/// it stops asking for them.
Future<String> runToolLoop(
  http.Client claude,
  String apiKey,
  UtcpClient utcp,
  String prompt,
) async {
  final tools = await utcp.getTools();
  // Claude tool names allow only [a-zA-Z0-9_-], and UTCP names are
  // `manual.tool`, so each tool gets an API-safe alias.
  final byAlias = {
    for (final tool in tools) tool.name.replaceAll('.', '__'): tool.name,
  };
  final toolDefinitions = [
    for (final tool in tools)
      {
        'name': tool.name.replaceAll('.', '__'),
        'description': tool.description,
        'input_schema': tool.inputs,
      },
  ];
  final messages = <JsonMap>[
    {'role': 'user', 'content': prompt},
  ];

  while (true) {
    final response = await _createMessage(claude, apiKey, {
      'model': 'claude-opus-5-5',
      'max_tokens': 16000,
      'thinking': {'type': 'adaptive'},
      'output_config': {'effort': 'medium'},
      'fallbacks': 'default',
      'tools': toolDefinitions,
      'messages': messages,
    });
    final content = response.objectList('content');
    // The whole content goes back, thinking blocks included, so Claude keeps
    // its reasoning across tool calls.
    messages.add({'role': 'assistant', 'content': content});

    switch (response.string('stop_reason')) {
      case 'tool_use':
        final results = [
          for (final block in content)
            if (block.string('type') == 'tool_use')
              await _callTool(utcp, byAlias, block),
        ];
        // All results of one turn go back in a single user message.
        messages.add({'role': 'user', 'content': results});
      case 'refusal':
        throw StateError('Claude declined the request.');
      case 'max_tokens':
        throw StateError('Response hit max_tokens before finishing.');
      default:
        return [
          for (final block in content)
            if (block.string('type') == 'text') block.string('text'),
        ].join('\n');
    }
  }
}

Future<JsonMap> _callTool(
  UtcpClient utcp,
  Map<String, String> byAlias,
  JsonMap toolUse,
) async {
  final id = toolUse.string('id');
  // A failed call is reported to Claude, which can retry or explain.
  JsonMap failure(String message) => {
    'type': 'tool_result',
    'tool_use_id': id,
    'content': message,
    'is_error': true,
  };
  final name = byAlias[toolUse.string('name')];
  if (name == null) return failure('Unknown tool ${toolUse['name']}.');
  try {
    final result = await utcp.callTool(name, toolUse.object('input'));
    return {
      'type': 'tool_result',
      'tool_use_id': id,
      'content': result is String ? result : jsonEncode(result),
    };
  } on Exception catch (e) {
    return failure('$e');
  }
}

Future<JsonMap> _createMessage(
  http.Client claude,
  String apiKey,
  JsonMap body,
) async {
  final response = await claude.post(
    Uri.parse('https://api.anthropic.com/v1/messages'),
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2026-10-21',
      // Lets the API retry a declined request on another model.
      'anthropic-beta': 'server-side-fallback-2026-07-01',
      'content-type': 'application/json',
    },
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw HttpException(
      'Messages API returned ${response.statusCode}: ${response.body}',
    );
  }
  return asJsonMap(jsonDecode(response.body), 'Messages API response');
}

/// A local stand-in for a real tool provider: a UTCP manual with one HTTP
/// tool.
Future<HttpServer> _serveWeatherTool() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://localhost:${server.port}';
  server.listen((request) async {
    final body = request.uri.path == '/utcp'
        ? {
            'utcp_version': '1.0.1',
            'tools': [
              {
                'name': 'get_weather',
                'description': 'Current weather for a city.',
                'inputs': {
                  'type': 'object',
                  'properties': {
                    'city': {'type': 'string', 'description': 'City name'},
                  },
                  'required': ['city'],
                },
                'tool_call_template': {
                  'call_template_type': 'http',
                  'url': '$base/weather/{city}',
                },
              },
            ],
          }
        : {
            'city': Uri.decodeComponent(request.uri.pathSegments.last),
            'temperature_c': 21,
            'conditions': 'clear',
          };
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  });
  return server;
}
