## Unreleased

- A cached OAuth2 token is dropped when the server answers 401 or 403, and a token that is not a usable bearer token is no longer cached.
- A `text/event-stream` response is recognized whatever the case of its Content-Type.
- Legacy HTTP+SSE MCP servers are supported: `transport` or `type` `sse` selects them, and an `http` server that answers its first request with 404 or 405 falls back to SSE. When the fallback fails too, the error gives the streamable HTTP status as well. `McpHttpServer.fromJson` reads `transport` and `type`, so an SSE server round-trips through `toJson`.
- **Breaking:** a server's `type` is read as MCP host configuration files write it, so `{"type": "sse"}`, which used to mean streamable HTTP, now selects legacy HTTP+SSE. `streamable-http`, `streamable_http` and `streamableHttp` are accepted as `http`.
- **Breaking:** a `ws://` or `wss://` server URL, which used to parse, is rejected when the config is parsed, with an error saying WebSocket MCP servers are not supported.
- **Breaking:** an `auth` object on an HTTP server, and any `auth` on a stdio server (`null` included), used to be dropped and now throw a `FormatException` naming the server. A string `auth` on an HTTP server is used as its bearer token, as MCP hosts write it.
- Resource tools are unique: resources that share a name, or whose `resource_<name>` is a tool's name, become `resource_<name>_<n>` in URI order, and a tool named `resource_<name>` is called instead of shadowed.
- A resource tool reads the URI it was registered with, without listing resources and tools again, even after the server's resources change. A manual must be registered with the protocol that calls it; otherwise its resource tools are sent as tool calls.
- Local `$ref`s in tool schemas are inlined, as the TypeScript SDK does, including under properties named `default`, `enum` or `const`. Cycles and malformed references stay references, and expansion is bounded.
- A JSON-RPC error from the server throws `McpRpcException`, whose `code` is the error code.
- A stdio `command` may be an array, as in the UTCP security guide: the first element is the command and the rest go before `args`.

## 0.1.1

- Docs: package cross-links, badges and platform notes.
- Runs on the web with streamable HTTP servers; there a stdio server fails discovery, and its tool calls throw a `UtcpException`, saying it needs a native platform. See the README's Platforms section for CORS and redirects in browsers.

## 0.1.0

- Initial release: the `mcp` call template and communication protocol, for MCP servers over stdio and streamable HTTP.
- Tools are discovered from every configured server and named `manual.server.tool`; resources can be registered as tools.
- Sessions are reused across calls, replaced when their connection drops, and closed with their last manual or on `close`.
- HTTP servers go through `HttpTransport` from `utcp`, with manual-level OAuth2, OAuth2 user, API key and Basic auth.
- A tool call is no longer retried after it may have reached the server; only listing and resource reads are retried on a fresh session.
- Discovery errors and logs name the server and command but never stdio `args`, `env`, headers or tokens, and carry no stack traces.
- `McpCallTemplate.endpoints` lists HTTP server URLs, so a remote manual cannot point `mcp` tools at a loopback server.
- Tool call and resource errors are redacted like discovery errors: refusing a plain HTTP server URL, or an error from the HTTP transport, no longer puts the URL's query or user info in the message, and percent-encoded values are masked too.
- Redaction no longer throws on non-UTF-8 percent escapes in a server URL, and the log line for a failed session end is redacted too.
