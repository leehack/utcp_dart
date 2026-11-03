# AGENTS.md

Dart SDK for the [Universal Tool Calling Protocol](https://github.com/universal-tool-calling-protocol/utcp-specification).
The specification is the quality bar; the Python and TypeScript SDKs are the
reference implementations. Read the spec page for a transport before changing
it, and encode any behavior the spec leaves open in a test.

## Layout

- `packages/utcp`: core client, data model, and the transports that run on
  every platform (`http`, `sse`, `streamable_http`, `text`). Its `lib/` stays
  free of `dart:io`; platform code goes behind a conditional import, as in
  `lib/src/env/`.
- `packages/utcp_<name>`: one package per transport that needs `dart:io` or a
  heavy dependency (`mcp`, `cli`, `file`, `socket`, `websocket`). A transport
  package depends on `utcp` and never the reverse.
- The root `pubspec.yaml` is a pub workspace. Add a new package to its
  `workspace:` list and to the CI matrix.

## Build and test

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
(cd packages/<package> && dart test)
(cd packages/utcp && dart test -p chrome test/unit)
```

- Tests are tagged by level (`dart_test.yaml` in each package):
  - `test/unit/` mirrors `lib/src/`, has no tag, and uses no network,
    processes or files outside a temp directory. Use `MockClient` and fakes.
  - `test/integration/` is tagged `integration`: real loopback servers,
    sockets, child processes and files.
  - `test/e2e/` is tagged `e2e`: a real provider and a `UtcpClient` talking
    through the public API, or an example run as a process.
- Every behavior change gets a test that fails without it. Cover malformed
  input and the security rules with negative tests.
- Tests close every server, process, socket, stream and client they open.

## Code

- Keep designs small and focused, without meaningful duplication. Add an
  abstraction only to cut real complexity or to protect a stable boundary.
- Reuse the shared building blocks instead of re-implementing them:
  - `JsonReader` (`json.dart`) to read decoded JSON.
  - `TypeRegistry` for every `*_type`-discriminated family.
  - `HttpTransport` and `buildToolRequest` for any HTTP request.
  - `requireCallTemplate` in protocols.
  - `VariableSubstitutor` for `${VAR}` handling.
- Type safety: the analyzer runs `strict-casts`, `strict-inference` and
  `strict-raw-types`. Never use `dynamic` or cast decoded JSON with `as`.
  JSON objects are `JsonMap`; read them through `JsonReader` or `asJsonMap`
  so a bad document fails with a `FormatException` naming the field. Use enums
  for closed sets of wire values and keep the wire spelling in `toJson`.
- A transport is a `CallTemplate` subclass and a `CommunicationProtocol`:
  - The template has a `static const type`, a `fromJson` factory, and
    `fieldsToJson` that round-trips through `fromJson`.
  - The protocol lists its templates in `callTemplateTypes`.
  - Discovery failures are returned with `RegisterManualResult.failure`,
    never thrown.
- Every HTTP-based transport applies the HTTP spec's security rules through
  `HttpTransport`: HTTPS or loopback only, every redirect re-validated, no
  redirect from a remote origin into loopback, credentials dropped across
  origins (any header that looks like a credential, static template headers
  included), no request body resent to another origin, and no loopback
  endpoint in a remotely discovered manual. Never call `http.Client`
  directly. A tool argument must never move a request onto loopback; only an
  explicit `{url}` template or a placeholder in the host lets it choose a
  remote host.
- A transport that reaches a network address overrides
  `CallTemplate.endpoints`, so the remote-loopback rule covers it without a
  check of its own.
- Parse YAML only with `decodeYaml`, which bounds alias expansion.
- Errors: throw the `UtcpException` hierarchy for protocol and runtime
  failures, `FormatException` for malformed documents, and `ArgumentError`
  for programming errors. Catch specific types; never `catch (e)` without an
  `on` clause.
- Keep credentials and secret-bearing values out of logs, error messages and
  serialized state.
- Public API has explicit types and `///` docs, and is exported from the
  package's main library. Implementation stays in `lib/src/`.
- Order imports SDK, package, then relative, with a blank line between
  groups.

## Changelog and releases

- Each package has its own `CHANGELOG.md` and version. New entries go under
  `## Unreleased`, one short user-facing bullet per change.
- Publish only in an explicit release task: move `Unreleased` into the new
  version, run `dart pub publish --dry-run` in the package, and publish the
  packages a release depends on first.

## Writing for people

PR bodies, issues, commit messages, changelog entries, docs and comments are
read by people. Lead with the outcome, say each thing once, and cut narration
and boilerplate. Code comments explain why (a non-obvious constraint or
trade-off), never what the code does.

## This file

When a task reveals a durable rule that changes agent behavior and that no
tool, test or linked doc covers, add it here. Point to docs instead of copying
them, delete stale rules, and leave out incident history.
