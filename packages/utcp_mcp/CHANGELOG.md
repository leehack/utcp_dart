## Unreleased

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
