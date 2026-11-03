## Unreleased

- **Breaking:** `UtcpClient.create` takes `protocols` as a list; each protocol declares its `callTemplateTypes`.
- **Breaking:** tool arguments are `Map<String, Object?>` and `Tool.inputs`/`outputs` are typed `JsonSchema`s.
- **Breaking:** `HttpCallTemplate.httpMethod` is an `HttpMethod` enum; `Auth.register` and `CallTemplate.register` moved to `Auth.registry` and `CallTemplate.registry`.
- Added `UtcpClient.fromJson` for the configuration format shared with the other UTCP SDKs.
- `HttpTransport` and `buildToolRequest` are public for transports built on HTTP.
- `http` manuals may be OpenAPI 2.0 or 3.x documents, converted to tools; `OpenApiConverter` converts documents loaded elsewhere.
- Added the `text` transport for UTCP manuals and OpenAPI documents supplied inline.
- Fixed an OAuth2 client secret sent in the token request body being resent to another origin on a 307/308 redirect.
- Fixed concurrent registrations of the same manual name both succeeding.
- Fixed loopback detection of decimal IPv4 addresses on the web.
- Added the `sse` transport: event-type filtering, `Last-Event-ID` reconnects, and streaming as events arrive.
- Added the `streamable_http` transport for NDJSON, JSON and chunked binary responses.
- Added `filter_dict` and `limit_strings` result post-processors, configured with `post_processing`.
- A timed-out or cancelled HTTP request now releases its connection.
- A remotely discovered manual may not point `sse` or `streamable_http` tools at loopback either.
- Requires `http` 1.6.0 or later.

## 0.1.0

- Initial release: UTCP manual, tool, call-template, and auth models.
- `UtcpClient` with manual registration, tool calls, streaming calls, and tag/description search.
- Namespaced `${VAR}` substitution from config, variable loaders, and the environment.
- HTTP transport with API key, Basic, OAuth2 client-credentials, and user OAuth2 auth.
- HTTPS-only remote requests, redirect re-validation, and auth stripping on cross-origin redirects.
