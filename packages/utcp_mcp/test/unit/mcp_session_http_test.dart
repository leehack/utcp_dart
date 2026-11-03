import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

/// A session-based (MCP 2025-06-18) streamable HTTP server, as most deployed
/// servers are: it rejects `server/discover`, hands out a session id on
/// `initialize`, ends the session on `DELETE`, and has no resources.
final class LegacyServer {
  final requests = <String>[];
  final sessions = <String?>[];
  Exception? deleteFailure;

  late final client = MockClient((request) async {
    final session = request.headers['mcp-session-id'];
    if (request.method == 'DELETE' && deleteFailure != null) {
      throw deleteFailure!;
    }
    if (request.method != 'POST') {
      requests.add(request.method);
      sessions.add(session);
      return http.Response('', request.method == 'DELETE' ? 200 : 405);
    }
    final message = asJsonMap(jsonDecode(request.body), 'message');
    final method = message.string('method');
    requests.add(method);
    sessions.add(session);
    final id = message['id'];
    if (id == null) return http.Response('', 202);
    final result = switch (method) {
      'initialize' => {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': <String, Object?>{}},
        'serverInfo': {'name': 'legacy', 'version': '1.0.0'},
      },
      'tools/list' => {
        'tools': [
          {
            'name': 'ping',
            'inputSchema': {'type': 'object'},
          },
        ],
      },
      'tools/call' => {
        'content': [
          {'type': 'text', 'text': 'pong'},
        ],
      },
      _ => null,
    };
    // Servers that predate server/discover reject it outright.
    if (method == 'server/discover') return http.Response('unsupported', 400);
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': ?result,
        if (result == null)
          'error': {'code': -32601, 'message': 'Method not found'},
      }),
      200,
      headers: {'content-type': 'application/json', 'mcp-session-id': 's1'},
    );
  });
}

void main() {
  setUpAll(silenceMcpLogs);

  late LegacyServer server;
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUp(() async {
    server = LegacyServer();
    protocol = McpCommunicationProtocol(httpClient: server.client);
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
  });

  McpCallTemplate manual({
    bool terminate = true,
    bool resources = false,
    String url = 'https://mcp.example.com/mcp',
  }) => McpCallTemplate(
    name: 'm',
    registerResourcesAsTools: resources,
    config: McpConfig(
      mcpServers: {
        'legacy': McpHttpServer(url: url, terminateOnClose: terminate),
      },
    ),
  );

  test('falls back to initialize and reuses the session', () async {
    final template = manual();
    final result = await protocol.registerManual(caller, template);
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(result.manual.tools.single.name, 'm.legacy.ping');
    expect(
      await protocol.callTool(caller, 'm.legacy.ping', const {}, template),
      'pong',
    );

    expect(server.requests.where((r) => r == 'initialize'), hasLength(1));
    final callIndex = server.requests.indexOf('tools/call');
    expect(server.sessions[callIndex], 's1');
  });

  test('ends the session on close when terminate_on_close is set', () async {
    await protocol.callTool(caller, 'm.legacy.ping', const {}, manual());
    expect(server.requests, isNot(contains('DELETE')));
    await protocol.close();
    expect(server.requests.last, 'DELETE');
    expect(server.sessions.last, 's1');
  });

  test('logs a failed session end without the URL query', () async {
    final url = 'https://mcp.example.com/mcp?token=SECRET-QUERY';
    server.deleteFailure = http.ClientException('failed', Uri.parse(url));
    final records = <String>[];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    addTearDown(() => Logger.root.level = level);
    final logs = Logger.root.onRecord.listen((r) => records.add(r.message));
    addTearDown(logs.cancel);
    await protocol.callTool(
      caller,
      'm.legacy.ping',
      const {},
      manual(url: url),
    );
    await protocol.close();
    final logged = records.where((r) => r.contains('terminate'));
    expect(logged, isNotEmpty);
    expect(logged, everyElement(isNot(contains('SECRET'))));
  });

  test('leaves the session open otherwise', () async {
    final template = manual(terminate: false);
    await protocol.callTool(caller, 'm.legacy.ping', const {}, template);
    await protocol.close();
    expect(server.requests, isNot(contains('DELETE')));
  });

  test('registers the tools of a server without resources', () async {
    final result = await protocol.registerManual(
      caller,
      manual(resources: true),
    );
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(result.manual.tools.map((t) => t.name), ['m.legacy.ping']);
    expect(server.requests.where((r) => r == 'initialize'), hasLength(1));
  });
}
