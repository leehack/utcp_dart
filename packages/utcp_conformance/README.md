# utcp_conformance

Checks the Dart UTCP packages against every UTCP JSON document in the
[specification](https://github.com/universal-tool-calling-protocol/utcp-specification)
and the [Python](https://github.com/universal-tool-calling-protocol/python-utcp) and
[TypeScript](https://github.com/universal-tool-calling-protocol/typescript-utcp) SDKs.
Not published.

```sh
dart test                    # check the corpus
dart run tool/harvest.dart   # re-harvest at refs.lock; exits 1 if the corpus differs
```

## Corpus

`refs.lock` pins the upstream commits and the spec version Dart targets.
`tool/harvest.dart` clones them, reads the spec's current docs and static
manuals and each SDK's Markdown and tests, and extracts every manual, tool,
call template, client config, auth, variable loader, post-processor, tool
repository and search strategy: from fenced code blocks, whole `.json`
files, and object literals in Python and TypeScript. A literal that holds
code other than a string expression is skipped, since its type is unknown.

Each document is one file in `fixtures/<repo>/`, named after its path and a
hash of its content:

| Field | Meaning |
| --- | --- |
| `source` | Repository, path and line it was found at |
| `kind` | What parses it (`manual`, `call_template`, ...) |
| `expect` | `accept` or `reject` (with a `FormatException`); `unreviewed` until someone decides |
| `reason` | Why: the spec rule, the reference SDK behaviour, or the docs bug |
| `may_drop` | Paths Dart may drop or rewrite on a round trip (`*` for any key or index) |
| `known_failure` | A Dart bug that keeps it from meeting `expect`; the test then requires it to fail, so a fix shows up |
| `document` | The document |

For every fixture, `dart test` checks the parse result and, for an accepted
document, that `toJson` → `fromJson` → `toJson` is stable and that nothing
outside `may_drop` is dropped or changed. An explicit `null` counts as
absent.

## Updating

The weekly *Spec drift* workflow harvests upstream HEAD and opens an issue
labelled `spec-drift` when it differs from the corpus. To update:

```sh
dart run tool/harvest.dart --head --write
```

This rewrites `fixtures/` and `refs.lock`, keeping the review of unchanged
documents. Review each new fixture (set `expect`, `reason`, `may_drop`), then
run `dart test` and update the commits in the root README's spec table.
`--checkouts <dir>` reads existing clones in `<dir>/<repo>` instead of
cloning.
