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

## Security

- Remote URLs must use HTTPS. Plain HTTP is allowed only to `localhost`, `127.0.0.1`, or `::1`.
- A manual fetched from a remote origin may not point tools or token URLs at loopback addresses. Tool
  arguments cannot move a request onto loopback.
- Every redirect hop is re-validated, and auth headers are dropped when a redirect changes origin.
- A manual's tools may only use the manual's own transport unless
  `allowed_communication_protocols` says otherwise.

## Extending

Additional transports implement `CommunicationProtocol` and register their call template parser:

```dart
CallTemplate.register('my_transport', MyCallTemplate.fromJson);
final client = await UtcpClient.create(protocols: {'my_transport': MyProtocol()});
```

Custom auth types register with `Auth.register`.

## Status

0.1.0 implements the core client and the HTTP transport. The following are not implemented yet:

- OpenAPI-to-manual conversion
- SSE and streamable HTTP transports
- MCP, CLI, and text/file transports
- Result post-processors

## License

MPL-2.0, the same license as the reference UTCP SDKs this package is ported from.
