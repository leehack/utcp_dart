import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  final specExample = <String, Object?>{
    'name': 'dev_mcp',
    'call_template_type': 'mcp',
    'config': {
      'mcpServers': {
        'filesystem': {
          'command': 'node',
          'args': ['dev-server.js'],
          'cwd': '/app/mcp',
          'env': {'NODE_ENV': 'development'},
        },
        'remote_api': {
          'transport': 'http',
          'url': 'https://api.example.com/mcp',
          'headers': {'X-Team': 'tools'},
          'timeout': 2.5,
        },
      },
    },
    'auth': {
      'auth_type': 'oauth2',
      'client_id': 'id',
      'client_secret': 'secret',
      'token_url': 'https://auth.example.com/token',
      'scope': 'mcp:access',
    },
    'register_resources_as_tools': true,
  };

  test('parses the spec example', () {
    final template = McpCallTemplate.fromJson(specExample);

    expect(template.name, 'dev_mcp');
    expect(template.registerResourcesAsTools, isTrue);
    expect(template.auth, isA<OAuth2Auth>());
    final servers = template.config.mcpServers;
    final stdio = servers['filesystem']! as McpStdioServer;
    expect(stdio.command, 'node');
    expect(stdio.args, ['dev-server.js']);
    expect(stdio.cwd, '/app/mcp');
    expect(stdio.env, {'NODE_ENV': 'development'});
    expect(stdio.timeout, const Duration(seconds: 30));
    final http = servers['remote_api']! as McpHttpServer;
    expect(http.url, 'https://api.example.com/mcp');
    expect(http.headers, {'X-Team': 'tools'});
    expect(http.timeout, const Duration(milliseconds: 2500));
    expect(http.sseReadTimeout, const Duration(seconds: 300));
    expect(http.terminateOnClose, isTrue);
    expect(http.notificationStreamMaxRetries, 0);
  });

  test('round-trips through toJson', () {
    final template = McpCallTemplate.fromJson(specExample);
    final again = McpCallTemplate.fromJson(template.toJson());
    expect(again.toJson(), template.toJson());
    expect(template.toJson()['config'], {
      'mcpServers': {
        'filesystem': {
          'transport': 'stdio',
          'command': 'node',
          'args': ['dev-server.js'],
          'env': {'NODE_ENV': 'development'},
          'cwd': '/app/mcp',
          'timeout': 30,
        },
        'remote_api': {
          'transport': 'http',
          'url': 'https://api.example.com/mcp',
          'headers': {'X-Team': 'tools'},
          'timeout': 2.5,
          'sse_read_timeout': 300,
          'terminate_on_close': true,
          'notification_stream_max_retries': 0,
        },
      },
    });
  });

  test('is parsed through the registry once the protocol is registered', () {
    CallTemplate.registry.register(
      McpCallTemplate.type,
      McpCallTemplate.fromJson,
    );
    expect(CallTemplate.fromJson(specExample), isA<McpCallTemplate>());
    expect(McpCommunicationProtocol().callTemplateTypes.keys, [
      McpCallTemplate.type,
    ]);
  });

  test('infers the transport of a server without one', () {
    expect(
      McpServerConfig.fromJson({'url': 'https://x.example/mcp'}),
      isA<McpHttpServer>(),
    );
    expect(McpServerConfig.fromJson({'command': 'x'}), isA<McpStdioServer>());
  });

  test('reads auth_token and HTTP options', () {
    final server =
        McpServerConfig.fromJson({
              'url': 'https://x.example/mcp',
              'auth_token': 't',
              'sse_read_timeout': 5,
              'terminate_on_close': false,
              'notification_stream_max_retries': 2,
            })
            as McpHttpServer;
    expect(server.authToken, 't');
    expect(server.sseReadTimeout, const Duration(seconds: 5));
    expect(server.terminateOnClose, isFalse);
    expect(server.notificationStreamMaxRetries, 2);
  });

  group('rejects', () {
    void rejects(Object? config, String message) => expect(
      () => McpCallTemplate.fromJson({
        'call_template_type': 'mcp',
        'config': config,
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains(message),
        ),
      ),
    );

    test('a missing config', () => rejects(null, "'config'"));
    test('a missing mcpServers', () => rejects({}, "'mcpServers'"));
    test('a server that is not an object', () {
      rejects({
        'mcpServers': {'s': 'node'},
      }, "'mcpServers.s'");
    });
    test('a server with neither command nor url', () {
      rejects({
        'mcpServers': {'s': <String, Object?>{}},
      }, "'command'");
    });
    test('an unsupported transport', () {
      rejects({
        'mcpServers': {
          's': {'transport': 'websocket', 'url': 'wss://x'},
        },
      }, "Unsupported transport 'websocket'");
    });
    test('mistyped fields', () {
      rejects({
        'mcpServers': {
          's': {'command': 'node', 'args': 'one'},
        },
      }, "'args'");
      rejects({
        'mcpServers': {
          's': {
            'command': 'node',
            'env': {'A': 1},
          },
        },
      }, "'env.A'");
    });
    test('a non-positive timeout', () {
      rejects({
        'mcpServers': {
          's': {'command': 'node', 'timeout': 0},
        },
      }, "'timeout'");
    });
    test('a negative reconnection budget', () {
      rejects({
        'mcpServers': {
          's': {'url': 'https://x', 'notification_stream_max_retries': -1},
        },
      }, 'notification_stream_max_retries');
    });
  });
}
