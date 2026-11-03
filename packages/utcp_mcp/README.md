# utcp_mcp

The `mcp` transport for the [Dart UTCP client](https://pub.dev/packages/utcp): discover and call
the tools of [Model Context Protocol](https://modelcontextprotocol.io) servers, over stdio or
streamable HTTP, through the same `UtcpClient` API as every other UTCP tool. Built on
[`mcp_dart`](https://pub.dev/packages/mcp_dart).

## Usage

```dart
import 'package:utcp/utcp.dart';
import 'package:utcp_mcp/utcp_mcp.dart';

Future<void> main() async {
  final client = await UtcpClient.fromJson({
    'manual_call_templates': [
      {
        'name': 'tools',
        'call_template_type': 'mcp',
        'config': {
          'mcpServers': {
            'filesystem': {
              'command': 'npx',
              'args': ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
            },
            'remote': {
              'transport': 'http',
              'url': 'https://mcp.example.com/mcp',
              'auth_token': r'${MCP_TOKEN}',
            },
          },
        },
      },
    ],
  }, protocols: [McpCommunicationProtocol()]);

  print(await client.callTool('tools.filesystem.list_directory', {'path': '/tmp'}));
  await client.close();
}
```

`${MCP_TOKEN}` is resolved like any UTCP variable, here from `tools_MCP_TOKEN`. A runnable
example with its own MCP server is in `example/utcp_mcp_example.dart`.

## Call template

`config.mcpServers` uses the server format of MCP host configuration files. An entry with
`command` is a stdio server and one with `url` is an HTTP server; `transport: "stdio"` or
`transport: "http"` makes the choice explicit.

| Field | Servers | Default | Meaning |
| --- | --- | --- | --- |
| `command`, `args` | stdio | `args: []` | Process to start. |
| `env` | stdio | `{}` | Added to this process's environment. |
| `cwd` | stdio | inherited | Working directory. |
| `url` | http | | Streamable HTTP endpoint. |
| `headers` | http | `{}` | Sent with every request. |
| `auth_token` | http | | Sent as `Authorization: Bearer <token>`. |
| `timeout` | both | `30` | Seconds allowed to connect and for each request. |
| `sse_read_timeout` | http | `300` | Longest silence tolerated on an event stream, in seconds. |
| `terminate_on_close` | http | `true` | End the server session (HTTP `DELETE`) on close. |
| `notification_stream_max_retries` | http | `0` | Reconnections of the server notification stream. |

The manual-level `auth` (`oauth2`, `oauth2_user`, `api_key` or `basic`) applies to HTTP servers
that carry no `auth_token` or `Authorization` header of their own. OAuth2 tokens are cached per
credential configuration and refreshed when they expire.

With `register_resources_as_tools: true`, each MCP resource is also registered as a tool named
`resource_<name>` that returns the resource's `contents`.

## Behavior

- Tools are named `manual.server.tool`, so tools of different servers never collide.
- A result's `structuredContent` is returned as is (a FastMCP `{"result": value}` wrapper around a
  non-object value is removed). Otherwise text content is parsed as JSON, then as a number, and
  returned as a string if neither applies; other content items are returned as their JSON. One item
  is returned on its own, several as a list. As in the Python and TypeScript SDKs, an `isError`
  result is returned the same way rather than thrown. JSON-RPC errors throw a `UtcpException`.
- One session per server, configuration and credentials is opened on first use and reused. A session
  whose connection drops is replaced. Listing tools or resources and reading a resource are retried
  once on a fresh session when the connection fails, as in the Python SDK. A tool call is retried
  only when `mcp_dart` rejected it before sending it; once it may have reached the server it is
  never sent again, since the tool may already have run. Sessions close when the last manual using
  them is deregistered; `close` ends every session and child process.
- Errors and logs name the server and, for stdio, its command, but never its `args`, `env`,
  headers or token, and carry no stack traces. An HTTP server's URL appears as scheme, host, port
  and path; its user info and query values are masked whether quoted decoded or percent-encoded.
  Values shorter than 4 characters are left as they are.
- MCP has no tool-level streaming, so `callToolStreaming` yields the whole result once.
- Child-process stderr is discarded. Set `UTCP_MCP_CHILD_STDERR=inherit` to see it.
- `mcp_dart` writes its own debug logs to stderr, including the full command line of a stdio server
  that fails to start. Call `silenceMcpLogs()` or `setMcpLogHandler()` from `package:mcp_dart` to
  change that.

## Platforms

Streamable HTTP servers work on every platform, browsers included (Flutter web, `dart compile js`
and `dart compile wasm`). stdio servers start a child process, so they need `dart:io`: the Dart VM,
or Flutter on desktop or mobile.

On the web:

- A stdio server fails like an unreachable one: discovery reports `Server '<name>': stdio MCP
  servers need a native platform ...` and calling one of its tools throws a `UtcpException`. One
  failed server fails the whole manual, so keep HTTP servers in a manual of their own.
- Requests go through the browser's `fetch` (`BrowserClient` from `package:http`), which streams
  responses, so the event streams of streamable HTTP work as on the VM.
- The server, and an OAuth2 token endpoint, must allow cross-origin requests from the page. An MCP
  server has to accept `POST`, `GET` and `DELETE` with the `Authorization`, `Content-Type`,
  `Mcp-Session-Id`, `MCP-Protocol-Version` and `Last-Event-ID` headers (plus any static
  `headers`), and list `Mcp-Session-Id` in `Access-Control-Expose-Headers`; without that the
  client cannot read the session id. `mcp_dart`'s `StreamableMcpServer` does all this for a page
  served from loopback.
- Every redirect fails the request with `Failed to fetch`. `HttpTransport` checks each hop itself,
  so it asks `package:http` not to follow redirects, and `fetch` can then only refuse them: a
  redirect it hands back unfollowed is opaque, without its status or `Location`, so the next hop
  cannot be checked. Use the server's final URL. Since no redirect is followed, no credential can
  reach another origin through one.
- Browsers drop a `Cookie` header set by the page, so `api_key` auth with `"location": "cookie"`
  sends nothing. Use a header or query API key.
- `UTCP_MCP_CHILD_STDERR` has no effect.

## Security

HTTP servers follow the same rules as the other UTCP HTTP transports, enforced by `HttpTransport`
from `package:utcp`: HTTPS anywhere, plain HTTP only to a literal loopback address, every redirect
re-validated (in browsers, refused; see [Platforms](#platforms)), no redirect from a remote host
into loopback, and credentials dropped when a redirect leaves the origin. OAuth2 token requests
follow no redirects at all, and the token must be a non-empty string of visible ASCII.

`mcp_dart`'s HTTP transport creates its own `http.Client` and takes none as a parameter.
`utcp_mcp` constructs it inside `http.runWithClient`, so that client is a wrapper that sends every
request through `HttpTransport`. Known gaps:

- The routing depends on `mcp_dart` creating its client through `http.Client()` when the transport
  is constructed, as `mcp_dart` 2.4 does.
- A token the server revokes before its `expires_in` keeps being sent until it expires locally,
  because the `utcp` token cache cannot be invalidated yet.
- Response bodies are read by `mcp_dart` without a size limit, so an HTTP server you register can
  make this process buffer a large JSON response or event in memory.
- WebSocket and legacy SSE MCP servers are not supported.

A stdio server runs with the privileges of this process, so register `mcp` manuals only from
configuration you trust. A manual fetched over HTTP cannot smuggle in `mcp` tools: the client drops
them unless that manual's call template lists `mcp` in `allowed_communication_protocols`. Even then,
`McpCallTemplate.endpoints` lists the HTTP server URLs, so a manual from a remote origin cannot
point an `mcp` tool at a loopback server.
