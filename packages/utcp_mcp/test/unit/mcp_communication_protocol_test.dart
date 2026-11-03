import 'package:mcp_dart/mcp_dart.dart' show silenceMcpLogs;
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

import '../support/in_memory.dart';

void main() {
  late InMemoryServers servers;
  late McpCommunicationProtocol protocol;
  late UtcpClient caller;

  setUpAll(silenceMcpLogs);

  setUp(() async {
    servers = InMemoryServers();
    protocol = McpCommunicationProtocol(transportFactory: servers.call);
    caller = await UtcpClient.create();
  });

  tearDown(() async {
    await protocol.close();
    expect(servers.open, 0, reason: 'close() closes every session');
    await caller.close();
    await servers.close();
  });

  group('registerManual', () {
    test('lists the tools of every server, named manual.server.tool', () async {
      final manual = inMemoryManual(['alpha', 'beta']);
      final result = await protocol.registerManual(caller, manual);

      expect(result.success, isTrue, reason: '${result.errors}');
      final names = result.manual.tools.map((t) => t.name);
      expect(names, containsAll(['manual.alpha.echo', 'manual.beta.echo']));
      expect(names.where((n) => n.startsWith('manual.alpha.')), hasLength(9));
      final echo = result.manual.tools.firstWhere(
        (t) => t.name == 'manual.alpha.echo',
      );
      expect(echo.description, 'This tool echoes back its input');
      expect(echo.inputs.required, ['message']);
      expect(echo.outputs.properties.keys, ['reply']);
      expect(echo.toolCallTemplate, same(manual));
    });

    test('registers resources as tools only when asked', () async {
      final without = await protocol.registerManual(
        caller,
        inMemoryManual(['alpha']),
      );
      expect(
        without.manual.tools.map((t) => t.name),
        isNot(contains('manual.alpha.resource_test_document')),
      );

      final withResources = await protocol.registerManual(
        caller,
        inMemoryManual(['alpha'], name: 'res', resources: true),
      );
      final tool = withResources.manual.tools.firstWhere(
        (t) => t.name == 'res.alpha.resource_test_document',
      );
      expect(tool.description, contains('file:///test_document.txt'));
      expect(tool.description, startsWith('Read resource: A test document'));
    });

    test('reports a failing server without dropping the others', () async {
      servers.failing.add('beta');
      final result = await protocol.registerManual(
        caller,
        inMemoryManual(['alpha', 'beta']),
      );

      expect(result.success, isFalse);
      expect(result.errors, ["Server 'beta': server beta is down"]);
      expect(
        result.manual.tools.map((t) => t.name),
        contains('manual.alpha.echo'),
      );
    });

    test('fails a manual without servers', () async {
      final result = await protocol.registerManual(
        caller,
        inMemoryManual(const []),
      );
      expect(result.success, isFalse);
      expect(result.errors.single, contains('no servers'));
    });
  });

  group('callTool', () {
    Future<Object?> call(String tool, [ToolArguments args = const {}]) =>
        protocol.callTool(
          caller,
          tool,
          args,
          inMemoryManual(['alpha', 'beta'], resources: true),
        );

    test('maps structured, text, numeric and list results', () async {
      expect(await call('manual.alpha.echo', {'message': 'hi'}), {
        'reply': 'you said: hi',
      });
      expect(await call('manual.alpha.greet', {'name': 'Ann'}), 'Hello, Ann!');
      expect(await call('manual.alpha.add_numbers', {'a': 5, 'b': 7}), 12);
      expect(await call('manual.alpha.list_items', {'count': 2}), [
        'item_0',
        'item_1',
      ]);
      expect(await call('manual.alpha.mixed'), [
        'plain',
        {'k': 1},
        {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
      ]);
    });

    test('returns an isError result as its content', () async {
      expect(await call('manual.alpha.fail'), 'boom');
    });

    test('routes each call to the server named in the tool', () async {
      expect(
        await call('manual.alpha.whoami'),
        containsPair('server', 'alpha'),
      );
      expect(await call('manual.beta.whoami'), containsPair('server', 'beta'));
      expect(await call('beta.whoami'), containsPair('server', 'beta'));
    });

    test('routes to the longest matching server name', () async {
      final manual = inMemoryManual(['a', 'a.b']);
      final result = await protocol.callTool(
        caller,
        'manual.a.b.whoami',
        const {},
        manual,
      );
      expect(result, containsPair('server', 'a.b'));
    });

    test('reads a resource through its resource tool', () async {
      final result = await call('manual.alpha.resource_test_document');
      expect(result, {
        'contents': [
          {
            'uri': 'file:///test_document.txt',
            'mimeType': 'text/plain',
            'text': 'This is a test document.',
          },
        ],
      });
    });

    test('rejects unknown resources, servers and tools', () async {
      await expectLater(
        call('manual.alpha.resource_missing'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains("Resource 'missing' not found"),
          ),
        ),
      );
      await expectLater(
        call('manual.gamma.echo'),
        throwsA(isA<UtcpException>()),
      );
      await expectLater(
        call('manual.alpha.nope'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            allOf(contains("MCP server 'alpha'"), contains('-32602')),
          ),
        ),
      );
    });

    test('reuses one session per server across calls', () async {
      await call('manual.alpha.echo', {'message': '1'});
      await call('manual.alpha.echo', {'message': '2'});
      await call('manual.beta.echo', {'message': '3'});
      expect(servers.connections, ['alpha', 'beta']);
    });

    test('a tool error keeps the session', () async {
      await expectLater(call('manual.alpha.nope'), throwsA(anything));
      await call('manual.alpha.echo', {'message': 'still here'});
      expect(servers.connections, ['alpha']);
    });

    test('replaces a session whose connection closed', () async {
      await call('manual.alpha.echo', {'message': '1'});
      await servers.killAll();
      expect(await call('manual.alpha.echo', {'message': '2'}), {
        'reply': 'you said: 2',
      });
      expect(servers.connections, ['alpha', 'alpha']);
    });

    test('keeps the session on a server-defined -32000 error', () async {
      await expectLater(
        call('manual.alpha.quota'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('Quota exceeded'),
          ),
        ),
      );
      expect(servers.connections, ['alpha']);
    });

    test('retries once when the connection drops mid-call', () async {
      await expectLater(
        call('manual.alpha.crash'),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains("MCP server 'alpha'"),
          ),
        ),
      );
      expect(servers.connections, ['alpha', 'alpha'], reason: 'one retry');
      await call('manual.alpha.echo', {'message': 'after'});
      expect(servers.connections, ['alpha', 'alpha', 'alpha']);
    });

    test('streams the result as a single chunk', () async {
      final chunks = await protocol.callToolStreaming(
        caller,
        'manual.alpha.echo',
        {'message': 's'},
        inMemoryManual(['alpha']),
      ).toList();
      expect(chunks, [
        {'reply': 'you said: s'},
      ]);
    });

    test('keeps sessions apart for different credentials', () async {
      const a = ApiKeyAuth(apiKey: 'a');
      const b = ApiKeyAuth(apiKey: 'b');
      for (final auth in [a, b, a]) {
        await protocol.callTool(caller, 'manual.alpha.echo', {
          'message': 'x',
        }, inMemoryManual(['alpha'], auth: auth));
      }
      expect(servers.connections, ['alpha', 'alpha']);
    });
  });

  group('lifecycle', () {
    test('deregistering the last manual closes its sessions', () async {
      final first = inMemoryManual(['alpha'], name: 'first');
      final second = inMemoryManual(['alpha'], name: 'first');
      await protocol.registerManual(caller, first);
      await protocol.registerManual(caller, second);
      expect(servers.connections, ['alpha']);

      await protocol.deregisterManual(caller, first);
      await protocol.callTool(caller, 'first.alpha.echo', {
        'message': 'x',
      }, second);
      expect(servers.connections, ['alpha'], reason: 'still shared');

      await protocol.deregisterManual(caller, second);
      await protocol.callTool(caller, 'first.alpha.echo', {
        'message': 'x',
      }, second);
      expect(servers.connections, ['alpha', 'alpha'], reason: 'redialed');
    });

    test('a failed registration releases its sessions', () async {
      servers.failing.add('beta');
      final manual = inMemoryManual(['alpha', 'beta']);
      await protocol.registerManual(caller, manual);
      await protocol.callTool(caller, 'manual.alpha.echo', {
        'message': 'x',
      }, manual);
      expect(servers.connections, ['alpha', 'alpha']);
    });

    test('close refuses further use', () async {
      await protocol.close();
      await expectLater(
        protocol.callTool(
          caller,
          'manual.alpha.echo',
          const {},
          inMemoryManual(['alpha']),
        ),
        throwsA(isA<UtcpException>()),
      );
    });

    test('close during a connection attempt leaves nothing open', () async {
      final pending = protocol.callTool(caller, 'manual.alpha.echo', {
        'message': 'x',
      }, inMemoryManual(['alpha']));
      final failed = expectLater(pending, throwsA(isA<UtcpException>()));
      await protocol.close();
      await failed;
      expect(servers.open, 0);
    });

    test('rejects call templates of other types', () {
      expect(
        () => protocol.callTool(
          caller,
          'x',
          const {},
          const HttpCallTemplate(url: 'https://example.com'),
        ),
        throwsArgumentError,
      );
    });
  });
}
