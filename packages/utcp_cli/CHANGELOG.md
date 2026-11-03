## Unreleased

- Initial release: `cli` call template and protocol with multi-step commands, injection-safe argument placeholders, `$CMD_<i>_OUTPUT` references, `env_vars`, `inherit_env_vars` and `working_dir`.
- Discovery from command output, JSON output decoding, and process-tree cleanup on timeout, cancellation and `close()`.
- Bash placeholders in arithmetic contexts (`$(( ))`, `(( ))`, `[[ -gt ]]`, `let`, `${...}`, array subscripts, `declare -i`) are rejected, since bash would run code embedded in the value.
- Placeholders inside `"$(...)"` and backticks stay one word and are never glob-expanded.
- A bash command that ends the script (`exit`, `exec`, `set -e`), or a script syntax error, fails the call instead of returning empty output.
- `CliCommunicationProtocol(maxOutputBytes: ...)` caps script output (10 MiB by default); a script over the limit is killed and the call fails.
- An argument containing a NUL character, and a blank command, are rejected.
- The README documents keeping secrets out of `command` and marks Windows support experimental.
