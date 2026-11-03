## Unreleased

- Docs: package cross-links, badges and platform notes.

## 0.1.0

- Initial release: `cli` call template and protocol with multi-step commands, injection-safe argument placeholders, `$CMD_<i>_OUTPUT` references, `env_vars`, `inherit_env_vars` and `working_dir`.
- Discovery from command output, JSON output decoding, and process-tree cleanup on timeout, cancellation and `close()`.
- Bash placeholders in arithmetic contexts (`$(( ))`, `(( ))`, `[[ -gt ]]`, `let`, `${...}`, array subscripts, `declare -i`) are rejected, since bash would run code embedded in the value.
- The bash scanner models heredocs (`<<`, `<<-`, quoted and unquoted delimiters), `case` statements, `{ }` groups and function bodies, and skips the wrapper words `builtin`, `command`, `time`, `exec`, `nohup`, `env` and a leading `\`, closing `let`/`declare -i` bypasses that the earlier first-word check missed. A placeholder in a quoted-delimiter heredoc body, or in a `case` inside a command substitution (unparseable on bash 3.2), is rejected.
- An argument value with a substitution (`$(`, `${`, `$name`, a backtick) inside `[...]` is rejected (naming the argument), as defense in depth against code in an array subscript. The joined values of one command are checked too, so a payload cannot be split across placeholders; text such as ``See [docs](https://x) and run `make` `` and JSON arrays such as `[1,2]` pass.
- The bash scanner treats `<<` in arithmetic as a shift instead of a heredoc, and rejects a placeholder after a heredoc inside a command substitution whose end bash versions read differently (`EOF)`), so neither can leave a later value unquoted.
- More contexts that evaluate a value as a number are rejected: `[...]=` in `name=(...)`, `[[ -v ]]` and `test -v`, an assignment to a variable declared `-i`, wrapper options (`command -p let`, `time -p let`) and a quoted command name (`'let'`).
- An escaped blank before `#` (`x\ #`) no longer starts a comment in the bash scanner.
- A command that installs a `trap '…' EXIT` no longer fails the call; the trap's output after the end marker is discarded.
- Placeholders inside `"$(...)"` and backticks stay one word and are never glob-expanded.
- A bash command that ends the script (`exit`, `exec`, `set -e`), or a script syntax error, fails the call instead of returning empty output.
- `CliCommunicationProtocol(maxOutputBytes: ...)` caps script output (10 MiB by default); a script over the limit is killed and the call fails.
- An argument containing a NUL character, and a blank command, are rejected.
- The README documents keeping secrets out of `command` and marks Windows support experimental.
