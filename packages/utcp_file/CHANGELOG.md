## Unreleased

- Relative file paths resolve against the client's `rootDir` when `FileCommunicationProtocol` has none.
- `FileCommunicationProtocol` registers the `dotenv` variable loader, so `DotEnvVariableLoader.register()` is no longer needed with it.

## 0.1.1

- Docs: package cross-links, badges and platform notes.

## 0.1.0

- Initial release: `file` call template and protocol that load UTCP manuals or OpenAPI documents from local JSON or YAML files and return file content from tool calls.
- `DotEnvVariableLoader` (`variable_loader_type: dotenv`) with python-dotenv parsing rules; register it with `DotEnvVariableLoader.register()`.
- A UTCP manual loaded from a file may not point tools at loopback, as OpenAPI documents already could not.
- `..` in a file path is resolved by the OS after following symlinks, instead of being collapsed first.
- `FileCommunicationProtocol(maxFileBytes: ...)` caps the size of a file that is read (10 MiB by default).
- The README explains that OpenAPI file manuals need `http` in `allowed_communication_protocols`.
