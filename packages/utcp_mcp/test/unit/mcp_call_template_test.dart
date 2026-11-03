import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  group('transport', () {
    McpServerConfig parse(JsonMap json) => McpServerConfig.fromJson(json);
    const url = 'https://x.example/mcp';

    test('accepts the names MCP hosts use, in transport or type', () {
      for (final name in [
        'http',
        'streamable-http',
        'streamable_http',
        'streamableHttp',
      ]) {
        for (final key in ['transport', 'type']) {
          final server = parse({key: name, 'url': url});
          expect(
            server,
            isA<McpHttpServer>().having(
              (s) => s.protocol,
              'protocol',
              McpHttpProtocol.streamableHttp,
            ),
            reason: '$key: $name',
          );
        }
      }
      expect(parse({'type': 'stdio', 'command': 'x'}), isA<McpStdioServer>());
    });

    test('sse selects the legacy transport and round-trips', () {
      for (final key in ['transport', 'type']) {
        final server = parse({key: 'sse', 'url': url});
        expect(
          server,
          isA<McpHttpServer>().having(
            (s) => s.protocol,
            'protocol',
            McpHttpProtocol.sse,
          ),
        );
        expect(server.toJson()['transport'], 'sse');
        expect(parse(server.toJson()).toJson(), server.toJson());
      }
    });

    test('McpHttpServer.fromJson reads the transport and round-trips', () {
      for (final protocol in McpHttpProtocol.values) {
        final server = McpHttpServer(url: url, protocol: protocol);
        expect(
          McpHttpServer.fromJson(server.toJson()).protocol,
          protocol,
          reason: protocol.wireName,
        );
      }
      expect(
        McpHttpServer.fromJson({'type': 'sse', 'url': url}).protocol,
        McpHttpProtocol.sse,
      );
      expect(
        () => McpHttpServer.fromJson({'transport': 'stdio', 'url': url}, 's'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("MCP server 's' is an HTTP server"),
          ),
        ),
      );
    });

    test('transport wins over type', () {
      final server = parse({'transport': 'http', 'type': 'sse', 'url': url});
      expect(
        (server as McpHttpServer).protocol,
        McpHttpProtocol.streamableHttp,
      );
    });
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

  test('reads a string auth as the bearer token, written as auth_token', () {
    final server =
        McpServerConfig.fromJson({'url': 'https://x.example/mcp', 'auth': 't'})
            as McpHttpServer;
    expect(server.authToken, 't');
    expect(server.toJson(), containsPair('auth_token', 't'));
    expect(server.toJson(), isNot(contains('auth')));
    final same =
        McpServerConfig.fromJson({
              'url': 'https://x.example/mcp',
              'auth': 't',
              'auth_token': 't',
            })
            as McpHttpServer;
    expect(same.authToken, 't');
  });

  test('reads command given as an array, prepended to args', () {
    final server =
        McpServerConfig.fromJson({
              'transport': 'stdio',
              'command': ['python', '-m', 'my_mcp_server'],
              'args': ['--verbose'],
            })
            as McpStdioServer;
    expect(server.command, 'python');
    expect(server.args, ['-m', 'my_mcp_server', '--verbose']);
    final again = McpServerConfig.fromJson(server.toJson()) as McpStdioServer;
    expect(again.toJson(), server.toJson());
    expect(again.command, 'python');
    expect(again.args, ['-m', 'my_mcp_server', '--verbose']);

    final single =
        McpServerConfig.fromJson({
              'command': ['node'],
            })
            as McpStdioServer;
    expect(single.command, 'node');
    expect(single.args, isEmpty);
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
    for (final url in ['ws://127.0.0.1:1/mcp', 'wss://x.example/mcp']) {
      test('a WebSocket URL ($url)', () {
        for (final transport in [null, 'http', 'sse']) {
          rejects({
            'mcpServers': {
              's': {'url': url, 'transport': ?transport},
            },
          }, "MCP server 's' has a WebSocket URL");
        }
      });
    }
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
    test('an auth object on a server', () {
      rejects({
        'mcpServers': {
          's': {
            'url': 'https://x',
            'auth': {'client_id': 'id'},
          },
        },
      }, "Field 'auth' of MCP server 's' must be a bearer token string");
    });
    test('auth and auth_token that differ', () {
      rejects({
        'mcpServers': {
          's': {'url': 'https://x', 'auth': 'a', 'auth_token': 'b'},
        },
      }, "MCP server 's' has both 'auth' and 'auth_token'");
    });
    test('auth on a stdio server', () {
      rejects({
        'mcpServers': {
          's': {'command': 'node', 'auth': 't'},
        },
      }, "MCP server 's' is a stdio server and cannot take 'auth'");
    });
    test('a command array that is empty or holds a non-string', () {
      rejects({
        'mcpServers': {
          's': {'transport': 'stdio', 'command': <Object?>[]},
        },
      }, "Field 'command' of MCP server 's' must not be an empty array");
      rejects({
        'mcpServers': {
          's': {
            'command': ['node', 1],
          },
        },
      }, "'command[1]'");
      rejects({
        'mcpServers': {
          's': {'command': 1},
        },
      }, "'command'");
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

  test('endpoints list the HTTP server URLs', () {
    final template = McpCallTemplate.fromJson({
      'call_template_type': 'mcp',
      'config': {
        'mcpServers': {
          'local': {'command': 'node'},
          'remote': {'url': 'https://mcp.example.com/mcp'},
        },
      },
    });
    expect(template.endpoints, ['https://mcp.example.com/mcp']);
  });

  test('an HTTP manual from a remote origin may not declare loopback MCP '
      'servers', () async {
    final client = await UtcpClient.create(
      protocols: [
        HttpCommunicationProtocol(
          transport: HttpTransport(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'utcp_version': '1.0.1',
                  'manual_version': '1.0.0',
                  'tools': [
                    {
                      'name': 'admin',
                      'tool_call_template': {
                        'call_template_type': 'mcp',
                        'config': {
                          'mcpServers': {
                            'admin': {'url': 'http://127.0.0.1:8080/mcp'},
                          },
                        },
                      },
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
        ),
        McpCommunicationProtocol(),
      ],
    );
    addTearDown(client.close);
    final result = await client.registerManual(
      CallTemplate.fromJson({
        'name': 'evil',
        'call_template_type': 'http',
        'url': 'https://evil.example/utcp',
        'http_method': 'GET',
        'allowed_communication_protocols': ['http', 'mcp'],
      }),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, contains('loopback'));
    expect(await client.searchTools(''), isEmpty);
  });
}
