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
  `workspace:` list, to the CI matrix, and to the tags in
  `.github/workflows/publish_pubdev.yml`.
- `tool/` holds the release scripts; their tests are in the root `test/`.

## Build and test

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test   # release tooling
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

## Changelog

Each package has its own `CHANGELOG.md` and version. New entries go under
`## Unreleased`, one short user-facing bullet per change.

## Releasing

Merging a release-prep PR publishes every package whose pubspec version is
not on pub.dev. Release only in an explicit release task, and never run
`dart pub publish` by hand.

1. On an up-to-date `main`, run
   `dart run tool/prepare_release.dart <package>:<major|minor|patch>...`.
   It bumps the versions and renames each `## Unreleased` to the new version.
   If the new `utcp` is outside a transport's `utcp` constraint, it raises the
   constraint, and that transport must be released too.
2. Run the git and `gh pr create` commands it prints. The PR comes from
   `release/prep-*` and carries the `release-prep` label.
3. Merge it. `release_on_prep_merge.yml` checks every unpublished version
   (semver, the first changelog heading, the `utcp` constraint,
   `dart pub publish --dry-run`) before pushing any tag. It then pushes
   `utcp-v<version>`, waits for it on pub.dev, and pushes the other
   `<package>-v<version>` tags, dispatching `publish_pubdev.yml` on each. That
   run publishes through pub.dev OIDC and creates a GitHub Release. Pushing a
   tag by hand also runs it.

To release what is already unpublished on `main`, run *Release on prep
merge* from the Actions tab on `main`.

One-time setup by the owner:

- Repository label `release-prep`.
- On pub.dev, for each package: Admin → Automated publishing → Enable
  publishing from GitHub Actions, repository `leehack/utcp_dart`, tag pattern
  `<package>-v{{version}}` (for example `utcp_mcp-v{{version}}`), with both
  push and workflow_dispatch events enabled. No secret is needed. A new
  package's first version must be published by hand.

When a run fails:

- A validation error pushes no tag. Fix it in a new release-prep PR.
- A *Publish to pub.dev* run that failed transiently: rerun it, then rerun
  the failed release run with *Re-run jobs* so it keeps the same commit. It
  skips published versions and reuses the tags it already pushed.
- A tag on another commit whose version is not on pub.dev blocks the
  release. Delete the tag if nothing should be published from it, or release
  that package at a new version.
- A version on pub.dev cannot be replaced; fix forward with a new version.

## Writing for people

PR bodies, issues, commit messages, changelog entries, docs and comments are
read by people. Lead with the outcome, say each thing once, and cut narration
and boilerplate. Code comments explain why (a non-obvious constraint or
trade-off), never what the code does.

A PR that changes behavior shows it in a Mermaid diagram in its body, which
GitHub renders: a flowchart for a decision, a sequence diagram for an
exchange between parties. Contrast before and after when that is the point.
Skip it when there is no behavior to show, such as a docs fix or a release.

## This file

When a task reveals a durable rule that changes agent behavior and that no
tool, test or linked doc covers, add it here. Point to docs instead of copying
them, delete stale rules, and leave out incident history.
