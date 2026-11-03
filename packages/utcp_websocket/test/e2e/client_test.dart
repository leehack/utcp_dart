@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

import '../support/websocket_server.dart';

void main() {
  late WebSocketTestServer server;
  late UtcpClient client;

  setUp(() async {
    server = await WebSocketTestServer.start(
      serving(
        () => manualFor(server.url, [
          {
            'name': 'add',
            'tags': ['math'],
            'message': {
              'op': 'add',
              'a': 'UTCP_ARG_a_UTCP_ARG',
              'b': 'UTCP_ARG_b_UTCP_ARG',
            },
            'response_format': 'json',
          },
          {
            'name': 'count',
            'header_fields': ['X-Trace'],
          },
        ]),
        respond: (socket, frame) {
          final request = asJsonMap(jsonDecode('$frame'), 'request');
          if (request.optString('op') == 'add') {
            socket.add(
              jsonEncode({
                'sum':
                    int.parse(request.string('a')) +
                    int.parse(request.string('b')),
              }),
            );
            return;
          }
          final n = request.optInt('n') ?? 0;
          for (var i = 1; i <= n; i++) {
            socket.add(jsonEncode({'type': 'tool_response', 'result': i}));
          }
          socket.add(jsonEncode({'type': 'stream_end'}));
        },
      ),
    );
    client = await UtcpClient.fromJson(
      {
        'manual_call_templates': [
          {
            'name': 'calc',
            'call_template_type': 'websocket',
            'url': r'ws://localhost:${PORT}/ws',
          },
        ],
        'variables': {'calc_PORT': '${server.port}'},
      },
      protocols: [WebSocketCommunicationProtocol()],
      environment: const {},
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('discovers and calls tools end to end', () async {
    final names = [for (final t in await client.getTools()) t.name];
    expect(names, ['calc.add', 'calc.count']);
    expect(await client.callTool('calc.add', {'a': 2, 'b': 40}), {'sum': 42});
    expect(
      await client.callToolStreaming('calc.count', {
        'n': 3,
        'X-Trace': 't1',
      }).toList(),
      [1, 2, 3],
    );
    expect(server.requests.last.headers.value('X-Trace'), 't1');
  });

  test('search and deregistration go through the client', () async {
    final found = await client.searchTools('add', anyOfTagsRequired: ['math']);
    expect(found.single.name, 'calc.add');
    await client.callTool('calc.add', {'a': 1, 'b': 1});
    final closed = server.closed.stream.first;
    expect(await client.deregisterManual('calc'), isTrue);
    await closed.timeout(const Duration(seconds: 2));
  });
}
