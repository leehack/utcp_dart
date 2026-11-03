@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../support/local_http_server.dart';

void main() {
  late LocalHttpServer server;
  late UtcpClient client;

  Future<void> stream(
    HttpRequest request,
    String type,
    List<String> parts,
  ) async {
    request.response
      ..bufferOutput = false
      ..headers.set('content-type', type);
    for (final part in parts) {
      request.response.write(part);
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    server = await LocalHttpServer.start((request, _) async {
      final base = server.baseUrl;
      switch (request.uri.path) {
        case '/sse/manual':
          request.response.json({
            'utcp_version': '1.0.1',
            'tools': [
              {
                'name': 'ticks',
                'tool_call_template': {
                  'call_template_type': 'sse',
                  'url': '$base/sse/ticks',
                  'event_type': 'tick',
                },
              },
            ],
          });
        case '/stream/manual':
          request.response.json({
            'utcp_version': '1.0.1',
            'tools': [
              {
                'name': 'rows',
                'tool_call_template': {
                  'call_template_type': 'streamable_http',
                  'url': '$base/stream/rows/{table}',
                  'auth': {
                    'auth_type': 'api_key',
                    'api_key': r'${TOKEN}',
                    'var_name': 'X-Api-Key',
                  },
                },
              },
            ],
          });
        case '/sse/ticks':
          await stream(request, 'text/event-stream', [
            'event: tick\ndata: {"n": 1, "secret": "s", "label": "first"}\n\n',
            ': keep-alive\n\n',
            'event: log\ndata: ignored\n\n',
            'event: tick\ndata: {"n": 2, "secret": "s", "label": "second"}\n\n',
          ]);
        case '/stream/rows/users'
            when request.headers.value('X-Api-Key') == 'k':
          await stream(request, 'application/x-ndjson', [
            '{"id": 1, "secret": "a", "name": "Ada Lovelace"}\n',
            '{"id": 2, "secret": "b", "name": "Alan Turing"}\n',
          ]);
        default:
          request.response.json({'error': 'denied'}, status: 401);
      }
    });
    client = await UtcpClient.fromJson({
      'variables': {'rows_TOKEN': 'k'},
      'manual_call_templates': [
        {
          'name': 'ticks',
          'call_template_type': 'sse',
          'url': '${server.baseUrl}/sse/manual',
        },
        {
          'name': 'rows',
          'call_template_type': 'streamable_http',
          'url': '${server.baseUrl}/stream/manual',
        },
      ],
      'post_processing': [
        {
          'tool_post_processor_type': 'filter_dict',
          'exclude_keys': ['secret'],
        },
        {
          'tool_post_processor_type': 'limit_strings',
          'limit': 3,
          'only_include_manuals': ['ticks'],
        },
      ],
    }, environment: const {});
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('both manuals are discovered', () async {
    expect((await client.getTools()).map((t) => t.name), [
      'ticks.ticks',
      'rows.rows',
    ]);
  });

  test('an SSE tool streams post-processed events', () async {
    expect(await client.callToolStreaming('ticks.ticks').toList(), [
      {'n': 1, 'label': 'fir'},
      {'n': 2, 'label': 'sec'},
    ]);
    expect(await client.callTool('ticks.ticks'), [
      {'n': 1, 'label': 'fir'},
      {'n': 2, 'label': 'sec'},
    ]);
  });

  test('a streamable HTTP tool streams post-processed rows', () async {
    final rows = <Object?>[];
    await for (final row in client.callToolStreaming('rows.rows', {
      'table': 'users',
    })) {
      rows.add(row);
    }
    expect(rows, [
      {'id': 1, 'name': 'Ada Lovelace'},
      {'id': 2, 'name': 'Alan Turing'},
    ]);
    await expectLater(
      client.callTool('rows.rows', {'table': 'admins'}),
      throwsA(isA<UtcpHttpException>()),
    );
  });

  test('stopping early ends the call', () async {
    expect(await client.callToolStreaming('ticks.ticks').first, {
      'n': 1,
      'label': 'fir',
    });
  });
}
