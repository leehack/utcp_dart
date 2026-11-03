# utcp

[![pub package](https://img.shields.io/pub/v/utcp.svg)](https://pub.dev/packages/utcp)
[![CI](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml)

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

## Flutter

The core works in Flutter apps on mobile, desktop and web, and has no Flutter dependency. Create the
client once, for example in `initState` or a provider, and close it in `dispose`:

```dart
class _ToolsState extends State<Tools> {
  late final Future<UtcpClient> _client = UtcpClient.create(
    config: UtcpClientConfig(
      manualCallTemplates: [
        HttpCallTemplate(name: 'weather', url: 'https://api.example.com/utcp'),
      ],
    ),
  );

  @override
  void dispose() {
    _client.then((client) => client.close());
    super.dispose();
  }
}
```

`utcp_websocket` also runs on the web. `utcp_mcp`, `utcp_cli`, `utcp_file` and `utcp_socket` need
`dart:io`: use them on mobile and desktop, not in a browser.

## LLM tool calling

Each `Tool` carries a name, a description and a JSON Schema for its inputs, which is what LLM
function-calling APIs take. Hand the tools to the model, then run each call it makes through
`callTool`:

```dart
final tools = [
  for (final tool in await client.getTools())
    {
      // Most LLM APIs allow only [a-zA-Z0-9_-] in tool names.
      'name': tool.name.replaceAll('.', '__'),
      'description': tool.description,
      'input_schema': tool.inputs, // `parameters` for OpenAI and Gemini
    },
];
// When the model asks for a tool, call it and send the result back:
final result = await client.callTool(utcpName, toolInput);
```

[`example/claude_tool_use.dart`](example/claude_tool_use.dart) runs the full loop against the
Claude Messages API: tool definitions, parallel tool calls, errors returned to the model, and
the final answer.

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

## Streaming transports

`sse` and `streamable_http` map arguments and auth the same way. Use `callToolStreaming` to get
results as they arrive; `callTool` collects them. Cancelling the stream subscription closes the
HTTP response.

- `sse` yields the `data` of each Server-Sent Event, JSON-decoded when it parses. `event_type`
  keeps only events of that type (an event without `event:` is `message`). A dropped stream is
  reopened with `Last-Event-ID`, waiting `retry_timeout` or the server's `retry:` (capped at 60 s),
  up to 5 times per call; calls that send a body are never re-issued. HTTP errors and responses
  that are not `text/event-stream` fail at once.
- `streamable_http` decodes the response by Content-Type: `application/x-ndjson` yields one value
  per line, `application/json` one value for the whole body, anything else `Uint8List` chunks of
  at most `chunk_size` bytes. `timeout` bounds the whole call, including reading the stream.

## Post-processing

`UtcpClientConfig.postProcessing` (`post_processing` in JSON) runs in order on every tool result
and every streamed chunk:

```json
"post_processing": [
  {"tool_post_processor_type": "filter_dict", "exclude_keys": ["internal_id"]},
  {"tool_post_processor_type": "limit_strings", "limit": 2000, "only_include_manuals": ["docs"]}
]
```

`filter_dict` removes keys (`exclude_keys`) or keeps only some (`only_include_keys`) at any depth.
`limit_strings` truncates every string to `limit` code points (default 10000). Both take
`exclude_tools`, `only_include_tools`, `exclude_manuals` and `only_include_manuals`. Custom
processors register with `ToolPostProcessor.registry.register`.

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
keys, the same name and location. The manual's static `headers` are sent only by generated tools on the spec's own origin, since they often carry credentials.

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

## Packages

| Package | Transports |
| --- | --- |
| [`utcp`](https://pub.dev/packages/utcp) | Core client, `http` (with OpenAPI conversion), `sse`, `streamable_http`, `text` |
| [`utcp_mcp`](https://pub.dev/packages/utcp_mcp) | `mcp` (MCP servers over stdio and streamable HTTP) |
| [`utcp_cli`](https://pub.dev/packages/utcp_cli) | `cli` |
| [`utcp_file`](https://pub.dev/packages/utcp_file) | `file`, `.env` variable loader |
| [`utcp_socket`](https://pub.dev/packages/utcp_socket) | `tcp`, `udp` |
| [`utcp_websocket`](https://pub.dev/packages/utcp_websocket) | `websocket` |

## License

MPL-2.0, the same license as the reference UTCP SDKs this package is ported from.
