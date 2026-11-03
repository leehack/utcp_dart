import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../../support/fixtures.dart';

void main() {
  group('buildToolRequest', () {
    test('maps header fields, body, path and query in that order', () {
      const template = HttpCallTemplate(
        url: 'https://api.example.com/users/{id}/notes',
        httpMethod: HttpMethod.post,
        headers: {'X-Static': 's'},
        headerFields: ['X-Request-Id'],
      );
      final request = buildToolRequest(template, {
        'id': 'a b/c',
        'X-Request-Id': 7,
        'body': {'text': 'hi'},
        'tags': ['x', 'y'],
        'filter': {'k': 1},
        'skip': null,
      });
      expect(request.method, HttpMethod.post);
      expect(request.uri.path, '/users/a%20b%2Fc/notes');
      expect(request.uri.queryParametersAll, {
        'tags': ['x', 'y'],
        'filter': ['{"k":1}'],
      });
      expect(request.headers, {
        'X-Static': 's',
        'X-Request-Id': '7',
        'Content-Type': 'application/json',
      });
      expect(jsonDecode(request.body!), {'text': 'hi'});
    });

    test('form bodies are url-encoded and an explicit content type wins', () {
      const template = HttpCallTemplate(
        url: 'https://a.example/f',
        httpMethod: HttpMethod.post,
        contentType: 'application/x-www-form-urlencoded',
      );
      final request = buildToolRequest(template, {
        'body': {'a': '1 2', 'b': true},
      });
      expect(request.body, 'a=1+2&b=true');
      expect(
        request.header('content-type'),
        'application/x-www-form-urlencoded',
      );
    });

    test('matches the form content type case-insensitively', () {
      const template = HttpCallTemplate(
        url: 'https://a.example/f',
        httpMethod: HttpMethod.post,
        contentType: 'Application/X-WWW-Form-Urlencoded',
      );
      final request = buildToolRequest(template, {
        'body': {'a': '1'},
      });
      expect(request.body, 'a=1');
    });

    test('missing path parameters are reported', () {
      expect(
        () =>
            buildToolRequest(const HttpCallTemplate(url: 'https://a/{id}'), {}),
        throwsA(isA<UtcpException>()),
      );
    });

    test('{url} takes the whole URL but cannot reach loopback', () {
      const template = HttpCallTemplate(url: '{url}');
      expect(
        buildToolRequest(template, {
          'url': 'https://b.example/x?q=1',
        }).uri.toString(),
        'https://b.example/x?q=1',
      );
      expect(
        () => buildToolRequest(template, {'url': 'http://127.0.0.1:9/secret'}),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('CR or LF in a header value is rejected', () {
      expect(
        () => buildToolRequest(
          const HttpCallTemplate(url: 'https://a', headerFields: ['X-A']),
          {'X-A': 'v\r\nInjected: 1'},
        ),
        throwsA(isA<UtcpSecurityException>()),
      );
    });
  });

  group('HttpTransport', () {
    HttpRequestSpec get(String url) =>
        HttpRequestSpec(HttpMethod.get, Uri.parse(url));

    test('applies each auth type', () async {
      final transport = HttpTransport(
        client: MockClient((_) async => http.Response('', 500)),
      );
      const timeout = Duration(seconds: 1);

      final header = get('https://a/x');
      await transport.authorize(
        header,
        const ApiKeyAuth(apiKey: 'k'),
        timeout: timeout,
      );
      expect(header.header('x-api-key'), 'k');

      final query = get('https://a/x?a=1');
      await transport.authorize(
        query,
        const ApiKeyAuth(
          apiKey: 'k',
          varName: 'key',
          location: ApiKeyLocation.query,
        ),
        timeout: timeout,
      );
      expect(query.uri.queryParameters, {'a': '1', 'key': 'k'});

      final cookie = get('https://a/x')..setHeader('Cookie', 'a=1');
      await transport.authorize(
        cookie,
        const ApiKeyAuth(
          apiKey: 'k',
          varName: 'sid',
          location: ApiKeyLocation.cookie,
        ),
        timeout: timeout,
      );
      expect(cookie.header('cookie'), 'a=1; sid=k');

      final basic = get('https://a/x');
      await transport.authorize(
        basic,
        const BasicAuth(username: 'u', password: 'p'),
        timeout: timeout,
      );
      expect(basic.header('authorization'), 'Basic dTpw');

      final user = get('https://a/x');
      await transport.authorize(
        user,
        const OAuth2UserAuth(accessToken: 't', varName: 'X-Token', prefix: ''),
        timeout: timeout,
      );
      expect(user.header('x-token'), 't');

      expect(
        transport.authorize(
          get('https://a'),
          const ApiKeyAuth(apiKey: ''),
          timeout: timeout,
        ),
        throwsA(isA<UtcpException>()),
      );
      expect(
        transport.authorize(
          get('https://a'),
          const OAuth2UserAuth(accessToken: ''),
          timeout: timeout,
        ),
        throwsA(isA<UtcpException>()),
      );
    });

    test(
      'OAuth2 tokens are cached, shared between concurrent calls, and keyed by config',
      () async {
        var fetches = 0;
        final transport = HttpTransport(
          client: MockClient((request) async {
            fetches++;
            expect(request.bodyFields['grant_type'], 'client_credentials');
            return jsonResponse({
              'access_token': 'tok$fetches',
              'expires_in': 3600,
            });
          }),
        );
        const auth = OAuth2Auth(
          tokenUrl: 'https://a/token',
          clientId: 'i',
          clientSecret: 's',
        );
        const timeout = Duration(seconds: 1);
        final requests = [
          get('https://a/1'),
          get('https://a/2'),
          get('https://a/3'),
        ];
        await Future.wait([
          for (final r in requests)
            transport.authorize(r, auth, timeout: timeout),
        ]);
        expect(requests.map((r) => r.header('authorization')).toSet(), {
          'Bearer tok1',
        });

        final other = get('https://a/4');
        await transport.authorize(
          other,
          const OAuth2Auth(
            tokenUrl: 'https://a/token',
            clientId: 'i',
            clientSecret: 'other',
          ),
          timeout: timeout,
        );
        expect(other.header('authorization'), 'Bearer tok2');
        expect(fetches, 2);
      },
    );

    group('OAuth2 token', () {
      const auth = OAuth2Auth(
        tokenUrl: 'https://a/token',
        clientId: 'i',
        clientSecret: 's',
      );
      const timeout = Duration(seconds: 1);

      test('accepts expires_in sent as a string', () async {
        for (final expiresIn in ['3600', 'soon']) {
          final transport = HttpTransport(
            client: MockClient(
              (_) async => jsonResponse({
                'access_token': 'tok',
                'expires_in': expiresIn,
              }),
            ),
          );
          addTearDown(transport.close);
          final request = get('https://a/x');
          await transport.authorize(request, auth, timeout: timeout);
          expect(request.header('authorization'), 'Bearer tok');
        }
      });

      test('is validated before it is cached', () async {
        final tokens = ['a b', 'a b', 'good'];
        final transport = HttpTransport(
          client: MockClient(
            (_) async => jsonResponse({'access_token': tokens.removeAt(0)}),
          ),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.authorize(get('https://a/x'), auth, timeout: timeout),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('usable bearer token'),
            ),
          ),
        );
        final request = get('https://a/x');
        await transport.authorize(request, auth, timeout: timeout);
        expect(request.header('authorization'), 'Bearer good');
      });

      for (final status in [401, 403]) {
        test('is dropped when the server answers $status', () async {
          var fetches = 0;
          final transport = HttpTransport(
            client: MockClient((request) async {
              if (request.url.path == '/token') {
                return jsonResponse({'access_token': 'tok${++fetches}'});
              }
              return http.Response('', status);
            }),
          );
          addTearDown(transport.close);
          Future<HttpRequestSpec> call() async {
            final request = get('https://a/tool');
            await transport.authorize(request, auth, timeout: timeout);
            await transport.send(request, context: 'test', timeout: timeout);
            return request;
          }

          await call();
          final retry = await call();
          expect(retry.header('authorization'), 'Bearer tok2');
          expect(fetches, 2);
        });
      }

      test('stays cached when the server accepts it', () async {
        var fetches = 0;
        final transport = HttpTransport(
          client: MockClient((request) async {
            if (request.url.path == '/token') {
              return jsonResponse({'access_token': 'tok${++fetches}'});
            }
            return http.Response('', 404);
          }),
        );
        addTearDown(transport.close);
        for (var i = 0; i < 2; i++) {
          final request = get('https://a/tool');
          await transport.authorize(request, auth, timeout: timeout);
          await transport.send(request, context: 'test', timeout: timeout);
        }
        expect(fetches, 1);
      });
    });

    test(
      'OAuth2 falls back to a Basic header, then reports both failures',
      () async {
        final seen = <String?>[];
        final transport = HttpTransport(
          client: MockClient((request) async {
            seen.add(request.headers['Authorization']);
            return request.headers.containsKey('Authorization')
                ? jsonResponse({'access_token': 'basic'})
                : jsonResponse({'error': 'invalid_client'}, 401);
          }),
        );
        final request = get('https://a/x');
        await transport.authorize(
          request,
          const OAuth2Auth(
            tokenUrl: 'https://a/token',
            clientId: 'u',
            clientSecret: 'p',
          ),
          timeout: const Duration(seconds: 1),
        );
        expect(request.header('authorization'), 'Bearer basic');
        expect(seen, [null, 'Basic dTpw']);

        final failing = HttpTransport(
          client: MockClient((_) async => jsonResponse({'error': 'nope'}, 401)),
        );
        await expectLater(
          failing.authorize(
            get('https://a/x'),
            const OAuth2Auth(
              tokenUrl: 'https://a/token',
              clientId: 'u',
              clientSecret: 'p',
            ),
            timeout: const Duration(seconds: 1),
          ),
          throwsA(
            isA<UtcpException>().having(
              (e) => e.message,
              'message',
              contains('nope'),
            ),
          ),
        );
      },
    );

    test(
      'redirects drop sensitive headers across origins and switch POST to GET',
      () async {
        final seen = <String, http.Request>{};
        final transport = HttpTransport(
          client: MockClient((request) async {
            seen[request.url.host] = request;
            return switch (request.url.host) {
              'a.example' => http.Response(
                '',
                302,
                headers: {'location': 'https://b.example/next'},
              ),
              _ => http.Response('ok', 200),
            };
          }),
        );
        final request =
            HttpRequestSpec(HttpMethod.post, Uri.parse('https://a.example/x'))
              ..setHeader('Authorization', 'secret', sensitive: true)
              ..setHeader('X-Plain', 'kept')
              ..setHeader('Content-Type', 'application/json')
              ..body = '{}';
        final result = await transport.send(
          request,
          context: 't',
          timeout: const Duration(seconds: 1),
        );
        expect(result.text, 'ok');
        expect(result.url.host, 'b.example');
        final hop = seen['b.example']!;
        expect(hop.method, 'GET');
        expect(hop.headers.containsKey('Authorization'), isFalse);
        expect(hop.headers['X-Plain'], 'kept');
        expect(hop.body, isEmpty);
      },
    );

    test(
      'redirects into loopback, to insecure URLs, or without end are refused',
      () async {
        Future<void> expectRefused(String location, {int maxRedirects = 5}) {
          final transport = HttpTransport(
            maxRedirects: maxRedirects,
            client: MockClient(
              (_) async =>
                  http.Response('', 307, headers: {'location': location}),
            ),
          );
          return expectLater(
            transport.send(
              get('https://a.example/x'),
              context: 't',
              timeout: const Duration(seconds: 1),
            ),
            throwsA(isA<UtcpException>()),
          );
        }

        await expectRefused('https://127.0.0.2/admin');
        await expectRefused('http://b.example/plain');
        await expectRefused('https://a.example/loop', maxRedirects: 2);
      },
    );

    test(
      'an OAuth2 secret in the body is never resent to another origin',
      () async {
        final hosts = <String>[];
        final transport = HttpTransport(
          client: MockClient((request) async {
            hosts.add(
              '${request.url.host} ${request.headers['Authorization']} '
              '${request.body}',
            );
            return request.url.host == 'auth.example'
                ? http.Response(
                    '',
                    307,
                    headers: {'location': 'https://evil.example/token'},
                  )
                : jsonResponse({'access_token': 'stolen'});
          }),
        );
        await expectLater(
          transport.authorize(
            get('https://a/x'),
            const OAuth2Auth(
              tokenUrl: 'https://auth.example/token',
              clientId: 'id',
              clientSecret: 'secret',
            ),
            timeout: const Duration(seconds: 1),
          ),
          throwsA(isA<UtcpException>()),
        );
        expect(hosts, everyElement(startsWith('auth.example')));
      },
    );

    test('static credential headers are dropped across origins', () async {
      final seen = <String, Map<String, String>>{};
      final transport = HttpTransport(
        client: MockClient((request) async {
          seen[request.url.host] = request.headers;
          return request.url.host == 'api.example.com'
              ? http.Response(
                  '',
                  302,
                  headers: {'location': 'https://evil.example.net/x'},
                )
              : http.Response('ok', 200);
        }),
      );
      final request = buildToolRequest(
        const HttpCallTemplate(
          url: 'https://api.example.com/x',
          headers: {
            'Authorization': 'Bearer SECRET',
            'X-MyApp-Token': 'SECRET2',
            'Cookie': 'sid=1',
            'Accept': 'application/json',
          },
        ),
        {},
      );
      await transport.send(
        request,
        context: 't',
        timeout: const Duration(seconds: 1),
      );
      expect(seen['api.example.com']!['Authorization'], 'Bearer SECRET');
      expect(seen['evil.example.net'], {'Accept': 'application/json'});
    });

    test('a request body is never resent to another origin', () async {
      final transport = HttpTransport(
        client: MockClient(
          (request) async => request.url.host == 'a.example'
              ? http.Response(
                  '',
                  307,
                  headers: {'location': 'https://b.example/x'},
                )
              : http.Response('ok', 200),
        ),
      );
      final request = HttpRequestSpec(
        HttpMethod.post,
        Uri.parse('https://a.example/x'),
      )..body = '{"secret":1}';
      await expectLater(
        transport.send(
          request,
          context: 't',
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('isCredentialHeader follows the Python SDK list and pattern', () {
      for (final name in [
        'Authorization',
        'Proxy-Authorization',
        'X-Api-Key',
        'X_API_KEY',
        'XApiKey',
        'X-MyApp-Token',
        'Session',
        'X-Secret',
      ]) {
        expect(isCredentialHeader(name), isTrue, reason: name);
      }
      for (final name in ['Accept', 'Content-Type', 'X-Request-Id', 'Monkey']) {
        expect(isCredentialHeader(name), isFalse, reason: name);
      }
    });

    test('the timeout covers reading the body', () async {
      final transport = HttpTransport(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.periodic(
              const Duration(milliseconds: 20),
              (_) => [1],
            ),
            200,
          ),
        ),
      );
      await expectLater(
        transport.send(
          get('https://a/x'),
          context: 'slow',
          timeout: const Duration(milliseconds: 60),
        ),
        throwsA(
          isA<UtcpException>().having(
            (e) => e.message,
            'message',
            contains('Timed out'),
          ),
        ),
      );
    });

    test('a timed-out request releases its response body', () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      addTearDown(body.close);
      final transport = HttpTransport(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      await expectLater(
        transport.send(
          get('https://a/x'),
          context: 'slow',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<UtcpException>()),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
    });

    test(
      'open throws for an error status and honours the abort trigger',
      () async {
        final body = StreamController<List<int>>();
        addTearDown(body.close);
        var status = 500;
        final transport = HttpTransport(
          client: MockClient.streaming(
            (_, _) async => status == 500
                ? http.StreamedResponse(Stream.value(utf8.encode('down')), 500)
                : http.StreamedResponse(body.stream, 200),
          ),
        );
        Future<HttpStreamedResult> open([Future<void>? abort]) =>
            transport.open(
              get('https://a/x'),
              context: 'ctx',
              timeout: const Duration(seconds: 1),
              errorContext: 'opening x',
              abortTrigger: abort,
            );
        await expectLater(
          open(),
          throwsA(
            isA<UtcpHttpException>().having(
              (e) => e.message,
              'message',
              'HTTP 500 opening x: down',
            ),
          ),
        );
        status = 200;
        final abort = Completer<void>();
        final response = await open(abort.future);
        final received = response.body.toList();
        abort.complete();
        await expectLater(
          received,
          throwsA(isA<http.RequestAbortedException>()),
        );
      },
    );
  });

  group('HttpResult', () {
    HttpResult result(
      String body, {
      String? contentType,
      int status = 200,
      String path = '/x',
    }) => HttpResult(
      status,
      'Reason',
      {'content-type': ?contentType},
      utf8.encode(body),
      Uri.parse('https://a$path'),
    );

    test('decodes by content type', () {
      expect(result('{"a":1}', contentType: 'application/json').decode(), {
        'a': 1,
      });
      expect(result('{"a":1}', contentType: 'text/plain').decode(), '{"a":1}');
      expect(result('{"a":1}').decode(sniffJson: true), {'a': 1});
      expect(result('ünïcode', contentType: 'text/plain').decode(), 'ünïcode');
    });

    test('parses only application/json and +json types as JSON', () {
      for (final type in [
        'application/json; charset=utf-8',
        'application/problem+json',
        'Application/JSON',
        'APPLICATION/VND.API+JSON',
      ]) {
        expect(result('{"a":1}', contentType: type).decode(), {'a': 1});
      }
      const ndjson = '{"a":1}\n{"a":2}\n';
      expect(
        result(ndjson, contentType: 'application/x-ndjson').decode(),
        ndjson,
      );
      expect(
        result('{"a":1}', contentType: 'text/jsonish').decode(),
        '{"a":1}',
      );
    });

    test('returns invalid JSON as text', () {
      expect(
        result('{not json', contentType: 'application/json').decode(),
        '{not json',
      );
      expect(result('{not json').decode(sniffJson: true), '{not json');
    });

    test('parses YAML only for manuals', () {
      expect(result('a: 1', path: '/m.yaml').decode(), 'a: 1');
      expect(result('a: 1', contentType: 'application/yaml').decode(), 'a: 1');
      expect(result('a: 1', path: '/m.yaml').decodeManual(), {'a': 1});
      expect(result('a: 1', path: '/m.yml').decodeManual(), {'a': 1});
      expect(result('a: 1', contentType: 'Application/YAML').decodeManual(), {
        'a': 1,
      });
      expect(result('{"a":1}', contentType: 'text/plain').decodeManual(), {
        'a': 1,
      });
    });

    test('errors carry the server reason, bounded and collapsed', () {
      void expectError(HttpResult r, Object message) => expect(
        () => r.ensureSuccess('ctx', maxDetailChars: 10),
        throwsA(
          isA<UtcpHttpException>().having((e) => e.message, 'message', message),
        ),
      );
      expectError(
        result('{"error":"quota"}', status: 429),
        'HTTP 429 ctx: quota',
      );
      expectError(
        result('{"error":{"code":1}}', status: 400),
        contains('{"error":{'),
      );
      expectError(result('', status: 503), 'HTTP 503 ctx: Reason');
      expectError(
        result('line1\nline2 and more text', status: 500),
        'HTTP 500 ctx: line1 line…',
      );
      result('fine').ensureSuccess('ctx');
    });
  });
}
