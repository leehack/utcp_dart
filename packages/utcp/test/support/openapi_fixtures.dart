import 'package:utcp/utcp.dart';

/// A petstore-style OpenAPI 3.0 document.
///
/// `listPets` is public, `createPet` and `showPetById` use the global API
/// key, and `deletePet` uses OAuth2 client credentials with a token URL
/// relative to the document. `Pet` and `Owner` reference each other.
JsonMap petstoreOpenApi3({
  String serverUrl = 'https://petstore.example.com/v1',
}) => {
  'openapi': '3.0.3',
  'info': {'title': 'Swagger Petstore', 'version': '1.0.0'},
  'servers': [
    {'url': serverUrl},
  ],
  'security': [
    {'api_key': <Object?>[]},
  ],
  'paths': {
    '/pets': {
      'get': {
        'operationId': 'listPets',
        'summary': 'List all pets',
        'tags': ['pets'],
        'security': <Object?>[],
        'parameters': [
          {
            'name': 'limit',
            'in': 'query',
            'description': 'How many items to return',
            'schema': {'type': 'integer', 'format': 'int32', 'maximum': 100},
          },
          {r'$ref': '#/components/parameters/TraceId'},
        ],
        'responses': {
          '200': {
            'description': 'A list of pets',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Pets'},
              },
            },
          },
        },
      },
      'post': {
        'operationId': 'createPet',
        'summary': 'Create a pet',
        'tags': ['pets'],
        'requestBody': {r'$ref': '#/components/requestBodies/NewPet'},
        'responses': {
          '201': {
            'description': 'The created pet',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Pet'},
              },
            },
          },
        },
      },
    },
    '/pets/{petId}': {
      'parameters': [
        {
          'name': 'petId',
          'in': 'path',
          'required': true,
          'description': 'The id of the pet',
          'schema': {'type': 'string'},
          'example': 'pet-1',
        },
      ],
      'get': {
        'operationId': 'showPetById',
        'description': 'Info for a specific pet',
        'tags': ['pets'],
        'responses': {
          '200': {r'$ref': '#/components/responses/PetResponse'},
        },
      },
      'delete': {
        'operationId': 'deletePet',
        'summary': 'Delete a pet',
        'security': [
          {
            'petstore_oauth': ['write:pets'],
          },
        ],
        'responses': {
          '204': {'description': 'Deleted'},
        },
      },
      'head': {
        'operationId': 'petExists',
        'responses': {
          '200': {'description': 'Exists'},
        },
      },
    },
    '/health': {
      'get': {
        'summary': 'Has no operationId',
        'responses': {
          '200': {'description': 'OK'},
        },
      },
    },
  },
  'components': {
    'parameters': {
      'TraceId': {
        'name': 'X-Trace-Id',
        'in': 'header',
        'schema': {'type': 'string'},
      },
    },
    'requestBodies': {
      'NewPet': {
        'description': 'Pet to add',
        'required': true,
        'content': {
          'application/json': {
            'schema': {r'$ref': '#/components/schemas/NewPet'},
            'example': {'name': 'Rex'},
          },
        },
      },
    },
    'responses': {
      'PetResponse': {
        'description': 'The pet',
        'content': {
          'application/json': {
            'schema': {r'$ref': '#/components/schemas/Pet'},
          },
        },
      },
    },
    'schemas': {
      'Pet': {
        'type': 'object',
        'required': ['id', 'name'],
        'properties': {
          'id': {'type': 'string'},
          'name': {'type': 'string'},
          'tag': {'type': 'string'},
          'owner': {r'$ref': '#/components/schemas/Owner'},
        },
      },
      'Owner': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'pets': {
            'type': 'array',
            'items': {r'$ref': '#/components/schemas/Pet'},
          },
        },
      },
      'NewPet': {
        'type': 'object',
        'required': ['name'],
        'properties': {
          'name': {'type': 'string'},
          'tag': {'type': 'string'},
        },
      },
      'Pets': {
        'type': 'array',
        'items': {r'$ref': '#/components/schemas/Pet'},
      },
    },
    'securitySchemes': {
      'api_key': {'type': 'apiKey', 'name': 'X-Api-Key', 'in': 'header'},
      'petstore_oauth': {
        'type': 'oauth2',
        'flows': {
          'clientCredentials': {
            'tokenUrl': '/oauth/token',
            'scopes': {'write:pets': 'Modify pets', 'read:pets': 'Read pets'},
          },
        },
      },
    },
  },
};

/// A petstore-style OpenAPI 2.0 (Swagger) document in YAML, protected by
/// HTTP basic auth. Without [host], the API is served from the document's
/// own host.
String petstoreSwaggerYaml({String? host}) =>
    '''
swagger: "2.0"
info:
  title: Petstore v2
  version: 1.0.0
${host == null ? '' : 'host: $host\nschemes: [http, https]'}
basePath: /v2
securityDefinitions:
  basicAuth:
    type: basic
security:
  - basicAuth: []
paths:
  /pet:
    post:
      operationId: addPet
      summary: Add a new pet to the store
      tags: [pet]
      parameters:
        - in: body
          name: pet
          description: Pet object to add
          required: true
          schema:
            \$ref: "#/definitions/Pet"
      responses:
        200:
          description: The added pet
          schema:
            \$ref: "#/definitions/Pet"
  /pet/findByStatus:
    get:
      operationId: findPetsByStatus
      summary: Finds pets by status
      tags: [pet]
      parameters:
        - name: status
          in: query
          required: true
          type: array
          items:
            type: string
            enum: [available, pending, sold]
      responses:
        200:
          description: Matching pets
          schema:
            type: array
            items:
              \$ref: "#/definitions/Pet"
definitions:
  Pet:
    type: object
    required: [name]
    properties:
      id:
        type: integer
        format: int64
      name:
        type: string
        example: doggie
''';
