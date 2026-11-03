@Tags(['integration'])
@TestOn('vm && posix')
library;

import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import '../support/processes.dart';

void main() {
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;
  late McpCallTemplate manual;
  late Directory cwd;

  setUpAll(silenceMcpLogs);

  setUp(() async {
    protocol = McpCommunicationProtocol();
    caller = await UtcpClient.create();
    cwd = await Directory.systemTemp.createTemp('utcp_mcp_stdio');
    manual = McpCallTemplate(
      name: 'local',
      config: McpConfig(
        mcpServers: {
          'tools': stdioTestServer(
            env: {'MCP_SERVER_NAME': 'from_env'},
            cwd: cwd.path,
          ),
        },
      ),
      registerResourcesAsTools: true,
    );
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
    await cwd.delete(recursive: true);
  });

  Future<Object?> call(String tool, [ToolArguments args = const {}]) =>
      protocol.callTool(caller, 'local.tools.$tool', args, manual);

  Future<JsonMap> whoami() async => asJsonMap(await call('whoami'), 'whoami');

  Future<int> serverPid() async => (await whoami()).optInt('pid')!;

  test('discovers the tools and resources of a child process', () async {
    final result = await protocol.registerManual(caller, manual);
    expect(result.success, isTrue, reason: '${result.errors}');
    expect(
      result.manual.tools.map((t) => t.name),
      containsAll([
        'local.tools.echo',
        'local.tools.crash',
        'local.tools.resource_test_document',
      ]),
    );
  });

  test('calls tools and maps their results', () async {
    await protocol.registerManual(caller, manual);
    expect(await call('echo', {'message': 'test'}), {
      'reply': 'you said: test',
    });
    expect(await call('greet', {'name': 'Alice'}), 'Hello, Alice!');
    expect(await call('list_items', {'count': 3}), [
      'item_0',
      'item_1',
      'item_2',
    ]);
    expect(await call('add_numbers', {'a': 5, 'b': 7}), 12);
    expect(await call('resource_test_document'), {
      'contents': [
        {
          'uri': 'file:///test_document.txt',
          'mimeType': 'text/plain',
          'text': 'This is a test document.',
        },
      ],
    });
  });

  test('starts the child with the configured env and cwd', () async {
    final server = await whoami();
    expect(server['server'], 'from_env');
    expect(
      Directory(server.string('cwd')).resolveSymbolicLinksSync(),
      cwd.resolveSymbolicLinksSync(),
    );
  });

  test('reports a JSON-RPC error and keeps the process', () async {
    final pid = await serverPid();
    await expectLater(
      call('missing'),
      throwsA(isA<McpRpcException>().having((e) => e.code, 'code', -32602)),
    );
    expect(await serverPid(), pid);
  });

  test('starts a command given as an array, as the spec writes it', () async {
    final server = stdioTestServer();
    final template = McpCallTemplate.fromJson({
      'name': 'array',
      'call_template_type': 'mcp',
      'config': {
        'mcpServers': {
          'tools': {
            'transport': 'stdio',
            'command': [server.command, ...server.args],
            'env': {'MCP_SERVER_NAME': 'from_array'},
          },
        },
      },
    });
    final result = await protocol.callTool(
      caller,
      'array.tools.whoami',
      const {},
      template,
    );
    expect(asJsonMap(result, 'whoami')['server'], 'from_array');
  });

  test('replaces a server process that died', () async {
    final pid = await serverPid();
    await expectLater(call('crash'), throwsA(isA<UtcpException>()));
    await waitForExit(pid);
    final replacement = await serverPid();
    expect(replacement, isNot(pid));
  });

  test('deregistering closes the child process', () async {
    await protocol.registerManual(caller, manual);
    final pid = await serverPid();
    await protocol.deregisterManual(caller, manual);
    await waitForExit(pid);
  });

  test('close terminates the child process', () async {
    final pid = await serverPid();
    expect(isRunning(pid), isTrue);
    await protocol.close();
    await waitForExit(pid);
  });

  test('reports a command that cannot start without its args', () async {
    final result = await protocol.registerManual(
      caller,
      const McpCallTemplate(
        name: 'broken',
        config: McpConfig(
          mcpServers: {
            'nothing': McpStdioServer(
              command: '/nonexistent/utcp-mcp-server',
              args: ['--token', 'SECRET-ARG-123'],
              env: {'API_KEY': 'SECRET-ENV-456'},
              timeout: Duration(seconds: 5),
            ),
          },
        ),
      ),
    );
    expect(result.success, isFalse);
    final error = result.errors.single;
    expect(error, startsWith("Server 'nothing':"));
    expect(error, contains('/nonexistent/utcp-mcp-server'));
    expect(error, isNot(contains('SECRET')));
    expect(error, isNot(contains('#0')));
  });
}
