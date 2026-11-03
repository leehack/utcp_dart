import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/src/mcp_http_client.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

void main() {
  late List<http.Request> sent;
  late Future<http.StreamedResponse> Function(http.Request) respond;

  setUp(() {
    sent = [];
    respond = (request) async => http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  McpHttpClient client({
    McpHttpServer server = const McpHttpServer(
      url: 'https://mcp.example.com/mcp',
    ),
    Auth? auth,
  }) {
    final mock = MockClient.streaming((request, body) async {
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = await body.toBytes();
      sent.add(copy);
      return respond(copy);
    });
    return McpHttpClient(
      server: server,
      auth: auth,
      connection: HttpTransport(client: mock),
      credentials: HttpTransport(client: mock, maxRedirects: 0),
    );
  }

  Future<http.Response> post(McpHttpClient client, [String url = '']) async {
    final response = await client.send(
      http.Request('POST', Uri.parse(url.isEmpty ? client.server.url : url))
        ..headers['content-type'] = 'application/json'
        ..body = '{"jsonrpc":"2.0"}',
    );
    return http.Response.fromStream(response);
  }

  test('forwards the request with the server headers and auth', () async {
    final response = await post(
      client(
        server: const McpHttpServer(
          url: 'https://mcp.example.com/mcp',
          headers: {'X-Team': 'tools'},
        ),
        auth: const ApiKeyAuth(apiKey: 'k', varName: 'X-Key'),
      ),
    );
    expect(response.statusCode, 200);
    expect(response.body, '{}');
    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.body, '{"jsonrpc":"2.0"}');
    expect(request.headers, containsPair('X-Team', 'tools'));
    expect(request.headers, containsPair('X-Key', 'k'));
  });

  test('prefers the server credentials over the manual auth', () async {
    const basic = BasicAuth(username: 'u', password: 'p');
    await post(
      client(
        server: const McpHttpServer(
          url: 'https://mcp.example.com/mcp',
          authToken: 'own',
        ),
        auth: basic,
      ),
    );
    await post(
      client(
        server: const McpHttpServer(
          url: 'https://mcp.example.com/mcp',
          headers: {'authorization': 'Token mine'},
        ),
        auth: basic,
      ),
    );
    expect(sent[0].headers['Authorization'], 'Bearer own');
    expect(sent[1].headers['authorization'], 'Token mine');
  });

  group('OAuth2', () {
    const oauth = OAuth2Auth(
      tokenUrl: 'https://auth.example.com/token',
      clientId: 'id',
      clientSecret: 'secret',
    );

    void tokenEndpoint(Object? token, {int status = 200, String? location}) {
      respond = (request) async {
        if (request.url.path != '/token') {
          return http.StreamedResponse(const Stream.empty(), 202);
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'access_token': token}))),
          status,
          headers: {'content-type': 'application/json', 'location': ?location},
        );
      };
    }

    test('fetches a token once and sends it as a bearer header', () async {
      tokenEndpoint('tok');
      final c = client(auth: oauth);
      await post(c);
      await post(c);
      expect(sent.map((r) => r.url.path), ['/token', '/mcp', '/mcp']);
      expect(sent[1].headers['Authorization'], 'Bearer tok');
      expect(sent[2].headers['Authorization'], 'Bearer tok');
    });

    test('refuses a redirect from the token endpoint', () async {
      tokenEndpoint(
        'tok',
        status: 307,
        location: 'https://evil.example.com/token',
      );
      await expectLater(
        post(client(auth: oauth)),
        throwsA(isA<UtcpException>()),
      );
      expect(sent.map((r) => r.url.host), everyElement('auth.example.com'));
    });

    test('rejects an insecure token URL before sending anything', () async {
      await expectLater(
        post(
          client(
            auth: const OAuth2Auth(
              tokenUrl: 'http://auth.example.com/token',
              clientId: 'id',
              clientSecret: 'secret',
            ),
          ),
        ),
        throwsA(isA<UtcpException>()),
      );
      expect(sent, isEmpty);
    });

    test('rejects a token that is not visible ASCII', () async {
      tokenEndpoint('a b');
      await expectLater(
        post(client(auth: oauth)),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('usable bearer token'),
          ),
        ),
      );
      expect(sent.map((r) => r.url.path), isNot(contains('/mcp')));
    });
  });

  group('redirects', () {
    void redirectTo(String location) {
      respond = (request) async => request.url.host == 'mcp.example.com'
          ? http.StreamedResponse(
              const Stream.empty(),
              307,
              headers: {'location': location},
            )
          : http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
    }

    test('never resends a request to another origin', () async {
      redirectTo('https://other.example.com/mcp');
      await expectLater(
        post(
          client(
            server: const McpHttpServer(
              url: 'https://mcp.example.com/mcp',
              headers: {'X-Team': 'tools'},
              authToken: 'secret',
            ),
          ),
        ),
        throwsA(isA<UtcpSecurityException>()),
      );
      expect(sent.map((r) => r.url.host), everyElement('mcp.example.com'));
    });

    test('drops the session id when a redirect leaves the origin', () async {
      redirectTo('https://other.example.com/mcp');
      final response = await client().send(
        http.Request('GET', Uri.parse('https://mcp.example.com/mcp'))
          ..headers['mcp-session-id'] = 'session-secret'
          ..headers['accept'] = 'text/event-stream',
      );
      await response.stream.drain<void>();
      expect(sent.map((r) => r.url.host), [
        'mcp.example.com',
        'other.example.com',
      ]);
      expect(sent[0].headers['mcp-session-id'], 'session-secret');
      expect(sent[1].headers.keys, isNot(contains('mcp-session-id')));
      expect(sent[1].headers['accept'], 'text/event-stream');
    });

    test('refuses a redirect to plain HTTP or into loopback', () async {
      for (final target in [
        'http://other.example.com/mcp',
        'https://127.0.0.1/mcp',
      ]) {
        redirectTo(target);
        await expectLater(
          post(client()),
          throwsA(isA<UtcpSecurityException>()),
        );
      }
    });
  });

  test('refuses an insecure server URL', () async {
    await expectLater(
      post(client(), 'http://mcp.example.com/mcp'),
      throwsA(isA<UtcpSecurityException>()),
    );
    expect(sent, isEmpty);
  });

  group('response body', () {
    late StreamController<List<int>> events;

    setUp(() {
      events = StreamController<List<int>>();
      respond = (request) async => http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    tearDown(() => events.close());

    test('ends when the request is aborted', () async {
      final abort = Completer<void>();
      final response = await client().send(
        http.AbortableRequest(
          'GET',
          Uri.parse('https://mcp.example.com/mcp'),
          abortTrigger: abort.future,
        ),
      );
      final body = response.stream.toList();
      events.add(utf8.encode('data: 1\n\n'));
      abort.complete();
      await expectLater(body, throwsA(isA<http.RequestAbortedException>()));
    });

    test('fails an event stream that stays silent too long', () async {
      final response = await client(
        server: const McpHttpServer(
          url: 'https://mcp.example.com/mcp',
          sseReadTimeout: Duration(milliseconds: 50),
        ),
      ).send(http.Request('GET', Uri.parse('https://mcp.example.com/mcp')));
      await expectLater(
        response.stream.toList(),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('No data'),
          ),
        ),
      );
    });
  });

  test(
    'the protocol fetches OAuth2 tokens without following redirects',
    () async {
      final requests = <Uri>[];
      final protocol = McpCommunicationProtocol(
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return request.url.path == '/token'
              ? http.Response(
                  '',
                  307,
                  headers: {'location': 'https://auth.example.com/token2'},
                )
              : http.Response(jsonEncode({'access_token': 'tok'}), 200);
        }),
      );
      final caller = await UtcpClient.create();
      addTearDown(caller.close);
      addTearDown(protocol.close);
      final result = await protocol.registerManual(
        caller,
        const McpCallTemplate(
          name: 'm',
          config: McpConfig(
            mcpServers: {
              'remote': McpHttpServer(url: 'https://mcp.example.com/mcp'),
            },
          ),
          auth: OAuth2Auth(
            tokenUrl: 'https://auth.example.com/token',
            clientId: 'id',
            clientSecret: 'secret',
          ),
        ),
      );
      expect(result.success, isFalse);
      expect(requests.map((u) => u.path), everyElement('/token'));
    },
  );

  test('the protocol rejects an insecure server URL at discovery', () async {
    final protocol = McpCommunicationProtocol(
      httpClient: MockClient((request) async {
        fail('no request may be sent');
      }),
    );
    final caller = await UtcpClient.create();
    addTearDown(caller.close);
    addTearDown(protocol.close);
    final result = await protocol.registerManual(
      caller,
      const McpCallTemplate(
        name: 'm',
        config: McpConfig(
          mcpServers: {'remote': McpHttpServer(url: 'http://example.com/mcp')},
        ),
      ),
    );
    expect(result.success, isFalse);
    expect(result.errors.single, contains('Security error'));
  });
}
