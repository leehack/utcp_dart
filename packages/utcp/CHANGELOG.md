## Unreleased

- **Breaking:** `ToolRepository` adds `removeTool` and `toJson`, and `ToolSearchStrategy` adds `toJson`; custom implementations must add them. `InMemoryToolRepository.removeTool` also drops the tool from its manual.
- `UtcpClientConfig.toJson` writes the shared configuration format and round-trips through `fromJson`; loaders are written when their new `VariableLoader.toJson` is not null.
- `tool_repository` and `tool_search_strategy` are parsed with `ToolRepository.registry` and `ToolSearchStrategy.registry`, so plugins can add their own types.
- `UtcpClient.fromFile` and `UtcpClientConfig.fromFile` read a JSON or YAML configuration file, and `UtcpClient` takes a `rootDir` for transports that resolve relative paths, like `root_dir` in Python and TypeScript.
- Manuals are written with `utcp_version` `1.1.0`, the spec version this package implements, from `utcpProtocolVersion`.
- Variables that start with `ref`, such as `$refresh_token`, are substituted; only a `$ref` not followed by a word character marks a JSON Schema reference, as in Python.
- Manual names keep Unicode letters and numbers when sanitized, as in Python, so `café` keeps its name and variable namespace.
- A client parses call templates with its own protocols first and no longer replaces parsers in `CallTemplate.registry`, so one client's protocols do not change parsing for other clients. Added `TypeRegistry.scoped`.
- `streamable_http` binary responses are regrouped into `chunk_size`-byte chunks, the last one possibly shorter, as the spec describes. Before, chunks were at most `chunk_size` and followed the network's reads.
- Docs: tag search follows the TypeScript SDK's scoring and `limit` (0 returns every tool), and `oauth2_user` auth is TypeScript-only.
- HTTP tool results are parsed as JSON only for `application/json` and `+json` content types, matched case-insensitively; other types (such as `application/x-ndjson`) and invalid JSON are returned as text instead of throwing, as the spec requires.
- Tool results are no longer parsed as YAML; YAML is read only for discovered manuals (`HttpResult.decodeManual`).
- OAuth2: `expires_in` sent as a string is accepted, an `access_token` that is not a usable bearer token is rejected before it is cached, and a cached token is dropped when the server answers 401 or 403.
- OpenAPI-generated http tools without a request body keep `body_field: "body"` instead of `null`, which the TypeScript SDK rejects.
- An unknown `dotenv` variable loader error says how to register it.

## 0.2.1

- Docs: package cross-links, badges and platform notes.
- Example: `example/claude_tool_use.dart` gives UTCP tools to an LLM through the Claude Messages API tool-use loop.

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
