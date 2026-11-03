import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:yaml/yaml.dart';

import '../../support/openapi_fixtures.dart';

void main() {
  final specUrl = Uri.parse('https://petstore.example.com/specs/openapi.json');

  UtcpManual convert(
    JsonMap spec, {
    Uri? from,
    Auth? authTools,
    String? baseUrl,
    Map<String, String> headers = const {},
  }) => OpenApiConverter(
    spec,
    specUrl: from,
    callTemplateName: 'manual',
    authTools: authTools,
    baseUrl: baseUrl,
    headers: headers,
  ).convert();

  Map<String, Tool> toolsOf(UtcpManual manual) => {
    for (final tool in manual.tools) tool.name: tool,
  };

  HttpCallTemplate templateOf(Tool tool) {
    final template = tool.toolCallTemplate;
    if (template is! HttpCallTemplate) throw TestFailure('Not an http tool');
    return template;
  }

  /// A one-operation OpenAPI 3 document.
  JsonMap spec3(
    JsonMap operation, {
    String server = 'https://api.example.com',
    JsonMap components = const {},
  }) => {
    'openapi': '3.1.0',
    'servers': [
      {'url': server},
    ],
    'paths': {
      '/op': {
        'post': {'operationId': 'op', ...operation},
      },
    },
    'components': components,
  };

  Auth? authFor(JsonMap scheme, {Uri? from, Auth? authTools}) {
    final manual = convert(
      spec3(
        {
          'security': [
            {'s': <Object?>[]},
          ],
        },
        components: {
          'securitySchemes': {'s': scheme},
        },
      ),
      from: from,
      authTools: authTools,
    );
    return templateOf(manual.tools.single).auth;
  }

  group('OpenAPI 3', () {
    final tools = toolsOf(convert(petstoreOpenApi3(), from: specUrl));

    test('each operation with an operationId and a supported method is a '
        'tool', () {
      expect(tools.keys, ['listPets', 'createPet', 'showPetById', 'deletePet']);
      final show = tools['showPetById']!;
      expect(show.description, 'Info for a specific pet');
      expect(show.tags, ['pets']);
      expect(tools['listPets']!.description, 'List all pets');
      final template = templateOf(show);
      expect(template.name, 'Swagger_Petstore');
      expect(template.url, 'https://petstore.example.com/v1/pets/{petId}');
      expect(template.httpMethod, HttpMethod.get);
      expect(template.bodyField, isNull);
      expect(templateOf(tools['deletePet']!).httpMethod, HttpMethod.delete);
    });

    test('path, query and header parameters, including path-level and '
        r'$ref parameters, become inputs', () {
      expect(tools['showPetById']!.inputs, {
        'type': 'object',
        'properties': {
          'petId': {
            'description': 'The id of the pet',
            'type': 'string',
            'examples': ['pet-1'],
          },
        },
        'required': ['petId'],
      });
      final list = tools['listPets']!;
      expect(list.inputs.properties.keys, ['limit', 'X-Trace-Id']);
      expect(list.inputs.properties['limit'], {
        'description': 'How many items to return',
        'type': 'integer',
        'format': 'int32',
        'maximum': 100,
      });
      expect(list.inputs.required, isEmpty);
      expect(templateOf(list).headerFields, ['X-Trace-Id']);
    });

    test('a request body becomes the body argument', () {
      final create = tools['createPet']!;
      expect(templateOf(create).bodyField, 'body');
      expect(templateOf(create).contentType, 'application/json');
      expect(create.inputs.required, ['body']);
      expect(create.inputs.properties['body'], {
        'description': 'Pet to add',
        'type': 'object',
        'required': ['name'],
        'properties': {
          'name': {'type': 'string'},
          'tag': {'type': 'string'},
        },
        'examples': [
          {'name': 'Rex'},
        ],
      });
    });

    test(r'outputs come from the success response with $refs inlined and '
        'cycles kept as references', () {
      final pet = tools['showPetById']!.outputs;
      expect(pet.types, ['object']);
      expect(pet.required, ['id', 'name']);
      final owner = pet.properties['owner']!;
      expect(owner.properties['pets']!.items, {
        r'$ref': '#/components/schemas/Pet',
      });
      final list = tools['listPets']!.outputs;
      expect(list.types, ['array']);
      expect(list.items!.properties.keys, ['id', 'name', 'tag', 'owner']);
      expect(tools['createPet']!.outputs.required, ['id', 'name']);
      expect(tools['deletePet']!.outputs, isEmpty);
    });

    test('form-encoded request bodies keep their content type', () {
      final tool = convert(
        spec3({
          'requestBody': {
            'content': {
              'application/x-www-form-urlencoded': {
                'schema': {
                  'type': 'object',
                  'properties': {
                    'q': {'type': 'string'},
                  },
                },
              },
            },
          },
        }),
      ).tools.single;
      expect(templateOf(tool).contentType, 'application/x-www-form-urlencoded');
      expect(tool.inputs.properties['body']!.properties.keys, ['q']);
      expect(tool.inputs.required, isEmpty);
    });

    test('examples are merged, de-duplicated by value and type, and '
        'non-JSON values dropped', () {
      final tool = convert(
        spec3({
          'requestBody': {
            'content': {
              'application/json': {
                'examples': {
                  'a': {
                    'value': {'a': 1, 'b': 2},
                  },
                  'b': {
                    'value': {'b': 2, 'a': 1},
                  },
                  'external': {'externalValue': 'https://x'},
                },
                'schema': {
                  'type': 'object',
                  'example': {'a': 1, 'b': 2},
                },
              },
            },
          },
          'responses': {
            '200': {
              'content': {
                'text/plain': {
                  'schema': {
                    'type': 'string',
                    'examples': [true, 1, 1, double.nan],
                  },
                },
              },
            },
          },
        }),
      ).tools.single;
      expect(tool.inputs.properties['body'], {
        'description': 'Request body',
        'type': 'object',
        'examples': [
          {'a': 1, 'b': 2},
        ],
      });
      expect(tool.outputs, {
        'type': 'string',
        'examples': [true, 1],
      });
    });

    test(r'$refs that fan out are bounded instead of expanding '
        'exponentially', () {
      final schemas = <String, Object?>{
        for (var i = 0; i < 40; i++)
          'S$i': {
            'type': 'object',
            'properties': {
              'a': {r'$ref': '#/components/schemas/S${i + 1}'},
              'b': {r'$ref': '#/components/schemas/S${i + 1}'},
            },
          },
        'S40': {'type': 'string'},
      };
      final tool = convert(
        spec3(
          {
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {r'$ref': '#/components/schemas/S0'},
                },
              },
            },
          },
          components: {'schemas': schemas},
        ),
      ).tools.single;
      var node = tool.inputs.properties['body']!;
      while (node.properties.isNotEmpty) {
        node = node.properties['b']!;
      }
      expect(node, contains(r'$ref'));
    });

    test(r'external, unresolvable and JSON-pointer-escaped $refs', () {
      final tool = convert(
        spec3(
          {
            'parameters': [
              {
                'name': 'a',
                'in': 'query',
                'schema': {r'$ref': 'other.yaml#/X'},
              },
              {
                'name': 'b',
                'in': 'query',
                'schema': {r'$ref': '#/components/schemas/Missing'},
              },
              {
                'name': 'c',
                'in': 'query',
                'schema': {r'$ref': '#/components/schemas/a~1b'},
              },
              {r'$ref': '#/components/parameters/Missing'},
            ],
          },
          components: {
            'schemas': {
              'a/b': {'type': 'boolean'},
            },
          },
        ),
      ).tools.single;
      expect(tool.inputs.properties, {
        'a': {'description': '', r'$ref': 'other.yaml#/X'},
        'b': {'description': '', r'$ref': '#/components/schemas/Missing'},
        'c': {'description': '', 'type': 'boolean'},
      });
    });
  });

  group('OpenAPI 2', () {
    JsonMap swagger({String? host}) =>
        asJsonMap(yamlToJson(loadYaml(petstoreSwaggerYaml(host: host))), 's');

    test('body and typed parameters map onto inputs', () {
      final tools = toolsOf(
        convert(swagger(host: 'petstore.example.com'), from: specUrl),
      );
      final add = tools['addPet']!;
      expect(templateOf(add).url, 'https://petstore.example.com/v2/pet');
      expect(templateOf(add).bodyField, 'body');
      expect(add.inputs.required, ['body']);
      expect(add.inputs.properties['body'], {
        'description': 'Pet object to add',
        'type': 'object',
        'required': ['name'],
        'properties': {
          'id': {'type': 'integer', 'format': 'int64'},
          'name': {'type': 'string', 'example': 'doggie'},
        },
      });
      expect(add.outputs.required, ['name']);

      final find = tools['findPetsByStatus']!;
      expect(templateOf(find).httpMethod, HttpMethod.get);
      expect(find.inputs.properties['status'], {
        'description': '',
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['available', 'pending', 'sold'],
        },
      });
      expect(find.outputs.types, ['array']);
      expect(find.outputs.items!.properties.keys, ['id', 'name']);
    });

    test('without a host the API is on the host serving the document', () {
      final manual = convert(
        swagger(),
        from: Uri.parse('http://127.0.0.1:8080/swagger.yaml'),
      );
      expect(
        templateOf(manual.tools.first).url,
        'http://127.0.0.1:8080/v2/pet',
      );
    });

    test('type basic becomes basic auth', () {
      final manual = convert(swagger(host: 'h.example.com'));
      expect(templateOf(manual.tools.first).auth?.toJson(), {
        'auth_type': 'basic',
        'username': r'${USERNAME_0}',
        'password': r'${PASSWORD_0}',
      });
    });
  });

  group('base URL', () {
    String urlFor(JsonMap spec, {Uri? from, String? baseUrl}) => templateOf(
      convert(spec, from: from, baseUrl: baseUrl).tools.single,
    ).url;

    JsonMap withServers(List<Object?>? servers) {
      final spec = spec3({})..remove('servers');
      return {...spec, 'servers': ?servers};
    }

    test('relative server URLs resolve against the spec URL', () {
      expect(
        urlFor(
          withServers([
            {'url': '/api/v3'},
          ]),
          from: specUrl,
        ),
        'https://petstore.example.com/api/v3/op',
      );
      expect(
        urlFor(
          withServers([
            {'url': 'v2/'},
          ]),
          from: specUrl,
        ),
        'https://petstore.example.com/specs/v2/op',
      );
      expect(
        urlFor(
          withServers([
            {'url': '//cdn.example.com/{stage}'},
          ]),
          from: specUrl,
        ),
        'https://cdn.example.com/{stage}/op',
      );
    });

    test('server variables take their defaults', () {
      expect(
        urlFor(
          withServers([
            {
              'url': 'https://{region}.example.com/{version}',
              'variables': {
                'region': {'default': 'eu'},
                'version': {
                  'enum': ['v1'],
                },
              },
            },
          ]),
        ),
        'https://eu.example.com/{version}/op',
      );
    });

    test('without servers the spec origin is used, then "/"', () {
      expect(
        urlFor(withServers(null), from: specUrl),
        'https://petstore.example.com/op',
      );
      expect(urlFor(withServers([])), '/op');
    });

    test('an explicit base URL wins', () {
      expect(
        urlFor(withServers(null), from: specUrl, baseUrl: 'https://x.dev/'),
        'https://x.dev/op',
      );
    });
  });

  group('security schemes', () {
    test('API keys in a header, query parameter or cookie', () {
      for (final location in ['header', 'query', 'cookie']) {
        expect(
          authFor({'type': 'apiKey', 'name': 'key', 'in': location})?.toJson(),
          {
            'auth_type': 'api_key',
            'api_key': r'${API_KEY_0}',
            'var_name': 'key',
            'location': location,
          },
        );
      }
    });

    test('HTTP basic and bearer', () {
      expect(authFor({'type': 'http', 'scheme': 'basic'}), isA<BasicAuth>());
      expect(authFor({'type': 'http', 'scheme': 'Bearer'})?.toJson(), {
        'auth_type': 'api_key',
        'api_key': r'Bearer ${API_KEY_0}',
        'var_name': 'Authorization',
        'location': 'header',
      });
      expect(authFor({'type': 'http', 'scheme': 'digest'}), isNull);
      expect(authFor({'type': 'openIdConnect'}), isNull);
    });

    test('OAuth2 prefers client credentials and resolves a relative token '
        'URL against the spec URL', () {
      final auth = authFor({
        'type': 'oauth2',
        'flows': {
          'authorizationCode': {
            'authorizationUrl': 'https://auth.example.com/authorize',
            'tokenUrl': 'https://auth.example.com/code-token',
          },
          'clientCredentials': {
            'tokenUrl': '../oauth/token',
            'scopes': {'read': '', 'write': ''},
          },
        },
      }, from: specUrl);
      expect(auth?.toJson(), {
        'auth_type': 'oauth2',
        'token_url': 'https://petstore.example.com/oauth/token',
        'client_id': r'${CLIENT_ID_0}',
        'client_secret': r'${CLIENT_SECRET_0}',
        'scope': 'read write',
      });
      expect(
        authFor({
          'type': 'oauth2',
          'flows': {
            'implicit': {'authorizationUrl': 'https://a.example.com'},
          },
        }),
        isNull,
      );
    });

    test('OpenAPI 2 OAuth2 flows with a token URL', () {
      JsonMap swagger(String flow) => {
        'swagger': '2.0',
        'host': 'api.example.com',
        'securityDefinitions': {
          'o': {
            'type': 'oauth2',
            'flow': flow,
            'tokenUrl': 'https://auth.example.com/token',
          },
        },
        'security': [
          {'o': <Object?>[]},
        ],
        'paths': {
          '/x': {
            'get': {'operationId': 'x'},
          },
        },
      };
      final auth = templateOf(
        convert(swagger('application')).tools.single,
      ).auth;
      expect(auth, isA<OAuth2Auth>());
      expect(
        templateOf(convert(swagger('password')).tools.single).auth,
        isNull,
      );
    });

    test('an insecure token URL is rejected', () {
      expect(
        () => authFor({
          'type': 'oauth2',
          'flows': {
            'clientCredentials': {'tokenUrl': 'http://auth.example.com/t'},
          },
        }),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('operation security replaces the global one; an empty list makes '
        'the operation public', () {
      final tools = toolsOf(convert(petstoreOpenApi3(), from: specUrl));
      expect(templateOf(tools['listPets']!).auth, isNull);
      expect(templateOf(tools['createPet']!).auth?.toJson(), {
        'auth_type': 'api_key',
        'api_key': r'${API_KEY_0}',
        'var_name': 'X-Api-Key',
        'location': 'header',
      });
      expect(
        templateOf(tools['showPetById']!).auth?.toJson(),
        containsPair('api_key', r'${API_KEY_1}'),
      );
      expect(templateOf(tools['deletePet']!).auth?.toJson(), {
        'auth_type': 'oauth2',
        'token_url': 'https://petstore.example.com/oauth/token',
        'client_id': r'${CLIENT_ID_2}',
        'client_secret': r'${CLIENT_SECRET_2}',
        'scope': 'write:pets read:pets',
      });
    });

    test('auth_tools replaces a compatible generated auth', () {
      const configured = ApiKeyAuth(apiKey: 'secret', varName: 'x-api-key');
      final apiKey = {'type': 'apiKey', 'name': 'X-API-Key', 'in': 'header'};
      expect(authFor(apiKey, authTools: configured), same(configured));
      expect(
        authFor({...apiKey, 'in': 'query'}, authTools: configured)?.toJson(),
        containsPair('api_key', r'${API_KEY_0}'),
      );
      expect(
        authFor({...apiKey, 'name': 'Other'}, authTools: configured)?.toJson(),
        containsPair('var_name', 'Other'),
      );
      expect(
        authFor({'type': 'http', 'scheme': 'basic'}, authTools: configured),
        isA<BasicAuth>(),
      );
      const basic = BasicAuth(username: 'u', password: 'p');
      expect(authFor({'type': 'basic'}, authTools: basic), same(basic));
      final public = convert(spec3({}), authTools: basic).tools.single;
      expect(templateOf(public).auth, isNull);
    });
  });

  test('static headers are sent by every tool', () {
    final manual = convert(petstoreOpenApi3(), headers: {'X-Client': 'utcp'});
    for (final tool in manual.tools) {
      expect(templateOf(tool).headers, {'X-Client': 'utcp'});
    }
  });

  test('the call template name comes from the title, else the given name', () {
    expect(
      OpenApiConverter({
        'info': {'title': 'My API (v2)'},
      }).callTemplateName,
      'My_API__v2_',
    );
    expect(
      OpenApiConverter({}, callTemplateName: 'given').callTemplateName,
      'given',
    );
    expect(
      OpenApiConverter({}).callTemplateName,
      matches(RegExp(r'^openapi_call_template_[0-9a-f]{32}$')),
    );
  });

  test('isOpenApi recognizes OpenAPI and Swagger documents', () {
    expect(OpenApiConverter.isOpenApi({'openapi': '3.0.0'}), isTrue);
    expect(OpenApiConverter.isOpenApi({'swagger': '2.0'}), isTrue);
    expect(OpenApiConverter.isOpenApi({'paths': {}}), isTrue);
    expect(OpenApiConverter.isOpenApi({'tools': []}), isFalse);
  });

  group('malformed documents fail with a FormatException naming the field', () {
    void expectFormatError(JsonMap spec, List<String> mentions) => expect(
      () => convert(spec),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf([for (final m in mentions) contains(m)]),
        ),
      ),
    );

    test('top-level fields', () {
      expectFormatError({'paths': <Object?>[]}, ["'paths'"]);
      expectFormatError({'paths': {}, 'servers': 'x'}, ["'servers'"]);
      expectFormatError(
        {
          'paths': {'/x': 'nope'},
        },
        ["Path '/x'"],
      );
    });

    test('operation fields name the operation', () {
      expectFormatError(spec3({'parameters': {}}), [
        'POST /op',
        "'parameters'",
      ]);
      expectFormatError(spec3({'operationId': 7}), [
        'POST /op',
        "'operationId'",
      ]);
      expectFormatError(
        spec3({
          'parameters': [
            {'name': 'a', 'in': 'query', 'required': 'yes'},
          ],
        }),
        ['POST /op', "'required'"],
      );
      expectFormatError(
        spec3(
          {
            'security': [
              {'s': <Object?>[]},
            ],
          },
          components: {
            'securitySchemes': {
              's': {'type': 'apiKey', 'name': 'k', 'in': 'body'},
            },
          },
        ),
        ['POST /op', "'in'"],
      );
    });
  });

  group('a spec from a remote origin', () {
    test('may not declare loopback servers or token URLs', () {
      for (final server in [
        'http://localhost:8080',
        'http://127.0.0.1:{port}/api',
      ]) {
        expect(
          () => convert(spec3({}, server: server), from: specUrl),
          throwsA(isA<UtcpSecurityException>()),
        );
      }
      expect(
        () => convert({
          'swagger': '2.0',
          'host': '127.0.0.1',
          'schemes': ['http'],
          'paths': {
            '/x': {
              'get': {'operationId': 'x'},
            },
          },
        }, from: specUrl),
        throwsA(isA<UtcpSecurityException>()),
      );
      expect(
        () => authFor({
          'type': 'oauth2',
          'flows': {
            'clientCredentials': {'tokenUrl': 'http://127.0.0.1/token'},
          },
        }, from: specUrl),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('may point at loopback through an explicit base URL', () {
      final manual = convert(
        spec3({}, server: 'http://localhost:8080'),
        from: specUrl,
        baseUrl: 'http://localhost:9090',
      );
      expect(templateOf(manual.tools.single).url, 'http://localhost:9090/op');
    });

    test('may keep a placeholder host, checked when the tool is called', () {
      final manual = convert(
        spec3({}, server: 'http://{host}:7777'),
        from: specUrl,
      );
      final template = templateOf(manual.tools.single);
      expect(template.url, 'http://{host}:7777/op');
      expect(
        () => buildToolRequest(template, {'host': '127.0.0.1'}),
        throwsA(isA<UtcpSecurityException>()),
      );
    });

    test('a loopback spec may declare loopback servers', () {
      final manual = convert(
        spec3({}, server: 'http://localhost:8080'),
        from: Uri.parse('http://localhost:8080/openapi.json'),
      );
      expect(templateOf(manual.tools.single).url, 'http://localhost:8080/op');
    });
  });
}
