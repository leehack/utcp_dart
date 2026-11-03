## Unreleased

- Docs: package cross-links, badges and platform notes.

## 0.2.0

- **Breaking:** `UtcpClient.create` takes `protocols` as a list; each protocol declares its `callTemplateTypes`.
- **Breaking:** tool arguments are `Map<String, Object?>` and `Tool.inputs`/`outputs` are typed `JsonSchema`s.
- **Breaking:** `HttpCallTemplate.httpMethod` is an `HttpMethod` enum; `Auth.register` and `CallTemplate.register` moved to `Auth.registry` and `CallTemplate.registry`.
- Added `UtcpClient.fromJson` for the configuration format shared with the other UTCP SDKs.
- `HttpTransport` and `buildToolRequest` are public for transports built on HTTP.
- `http` manuals may be OpenAPI 2.0 or 3.x documents, converted to tools; `OpenApiConverter` converts documents loaded elsewhere.
- Added the `text` transport for UTCP manuals and OpenAPI documents supplied inline.
- Added `substituteArgumentPlaceholders` and `utcpDiscoveryMessage` for transports that send `UTCP_ARG_<name>_UTCP_ARG` templates.
- Redirects to another origin drop every credential-like header, static template headers included, and a request body is never resent to another origin.
- The remote-loopback rule covers every transport through `CallTemplate.endpoints`.
- YAML alias expansion is bounded (`decodeYaml`), so a small hostile document cannot exhaust memory or CPU; aliases and collections used as mapping keys are rejected. Nesting too deep to parse fails with a `FormatException` instead of a stack overflow.
- OpenAPI-generated tools send the manual's static headers only to the spec's own origin, and a spec reached through a cross-origin redirect gets neither those headers nor `auth_tools` (a warning is logged).
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
