@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/src/stdio_transport.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUp(() async {
    protocol = McpCommunicationProtocol();
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    await caller.close();
  });

  const manual = McpCallTemplate(
    name: 'local',
    config: McpConfig(
      mcpServers: {
        'files': McpStdioServer(command: 'mcp-files', args: ['--token=s3cr3t']),
      },
    ),
  );

  test('reports a stdio server as a discovery failure', () async {
    final result = await protocol.registerManual(caller, manual);
    expect(result.success, isFalse);
    expect(result.manual.tools, isEmpty);
    expect(
      result.errors.single,
      "Server 'files': stdio MCP servers need a native platform (the Dart VM "
      'or Flutter on desktop or mobile); on the web, use a streamable HTTP '
      'server.',
    );
  });

  test('fails a stdio tool call with a UtcpException', () async {
    await expectLater(
      protocol.callTool(caller, 'local.files.read', const {}, manual),
      throwsA(
        isA<UtcpException>().having(
          (e) => e.message,
          'message',
          contains('need a native platform'),
        ),
      ),
    );
  });

  test('classifies no error as an IOException', () {
    expect(isIOException(StateError('closed')), isFalse);
  });
}
