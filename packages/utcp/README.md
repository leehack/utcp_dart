# utcp

A Dart client for the [Universal Tool Calling Protocol (UTCP)](https://github.com/universal-tool-calling-protocol).

UTCP lets an agent call tools directly through their native interfaces. A provider publishes a
*manual*: a JSON or YAML document that lists its tools, their input/output JSON Schemas, and how to call
each one. The client fetches the manual, then calls the tool's own endpoint. There is no wrapper server
in between.

## Usage

```dart
import 'package:utcp/utcp.dart';

Future<void> main() async {
  final client = await UtcpClient.create(
    config: UtcpClientConfig(
      variables: {'weather_API_KEY': 'my-key'},
      manualCallTemplates: [
        HttpCallTemplate(name: 'weather', url: 'https://api.example.com/utcp'),
      ],
    ),
  );

  final tools = await client.searchTools('current weather');
  final result = await client.callTool(tools.first.name, {'city': 'Seoul'});
  print(result);

  await client.close();
}
```

Tool names are prefixed with their manual name (`weather.get_weather`). `Tool.inputs` holds the
JSON Schema you hand to an LLM as the tool definition.

A runnable end-to-end example against a local server is in `example/utcp_example.dart`.

## Variables

Call templates can reference `${VAR}` or `$VAR`. Values are resolved from
`UtcpClientConfig.variables`, then any `VariableLoader`s, then the process environment.

Inside a manual, variables are namespaced by the manual name, with underscores in the name doubled:
`${API_KEY}` in manual `my_api` resolves `my__api_API_KEY`. This matches the Python and TypeScript SDKs.

## HTTP call templates

Tool arguments are mapped onto the request in this order:

1. `header_fields` become request headers.
2. `body_field` (default `body`) becomes the request body.
3. `{name}` placeholders in `url` become path segments.
4. Any remaining arguments become query parameters.

Supported auth types are `api_key` (header, query, or cookie), `basic`, `oauth2` (client
credentials, with token caching), and `oauth2_user` (a pre-provisioned bearer token).

## OpenAPI

An `http` manual URL may serve an OpenAPI 2.0 (Swagger) or 3.x document, in JSON or YAML, instead of
a UTCP manual. Each operation with an `operationId` becomes a tool of that name: header parameters
become `header_fields`, the request body becomes the `body` argument, and path parameters stay
`{name}` placeholders. Local `$ref`s are inlined. Relative server and OAuth2 token URLs resolve against
the URL the document was fetched from.

Security schemes become auth with variable placeholders such as `${API_KEY_0}`, resolved as
`petstore_API_KEY_0` in manual `petstore` (`apiKey`, HTTP `basic`, HTTP `bearer`, and OAuth2 flows
with a token URL). Set `auth_tools` on the manual call
template to supply the credentials instead; it replaces generated auth of the same type and, for API
keys, the same name and location. The manual's static `headers` are sent with every generated tool.

To convert a document you loaded yourself, use `OpenApiConverter(spec, specUrl: ...).convert()`.

## Text call templates

A `text` call template carries a UTCP manual or OpenAPI document inline in `content`, as JSON or YAML,
so it works on every platform. `base_url` replaces an OpenAPI document's servers. The tools converted
from OpenAPI use `http`, so list it in `allowed_communication_protocols`. Inline OpenAPI documents are
treated as remote: their tools may target loopback only through `base_url`. Calling a tool whose call
template is `text` returns its `content`.

## Security

- Remote URLs must use HTTPS. Plain HTTP is allowed only to `localhost`, `127.0.0.1`, or `::1`.
- A manual or OpenAPI document fetched from a remote origin may not point tools or token URLs at
  loopback addresses. Tool arguments cannot move a request onto loopback.
- Every redirect hop is re-validated, and auth headers are dropped when a redirect changes origin.
- A manual's tools may only use the manual's own transport unless
  `allowed_communication_protocols` says otherwise.

## Extending

A transport is a `CommunicationProtocol` that lists the call template types it serves. Pass it to the
client, which registers its parsers:

```dart
final client = await UtcpClient.create(protocols: [MyProtocol()]);
```

Custom auth types register with `Auth.registry.register`.

## Status

This version implements the core client and the `http` and `text` transports. The following are not
implemented yet:

- SSE and streamable HTTP transports
- MCP, CLI, and file transports
- Result post-processors

## License

MPL-2.0, the same license as the reference UTCP SDKs this package is ported from.
