# utcp_cli

[![pub package](https://img.shields.io/pub/v/utcp_cli.svg)](https://pub.dev/packages/utcp_cli)
[![CI](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml)

The `cli` transport for the [UTCP](https://github.com/universal-tool-calling-protocol) Dart client
([`utcp`](https://pub.dev/packages/utcp)). A manual is discovered by running commands that print a
UTCP manual, and each tool call runs the tool's commands with its arguments. As in the Python SDK,
the output may also be a list of tools or a single tool, or have one JSON object per line among
log lines. A tool that does not parse is skipped with a warning on the `utcp.cli` logger.

## Usage

```dart
import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';

Future<void> main() async {
  final client = await UtcpClient.create(
    config: UtcpClientConfig(
      manualCallTemplates: [
        // Any command that prints a UTCP manual as JSON.
        CliCallTemplate(
          name: 'tools',
          commands: [const CommandStep('my-tool --utcp-manual')],
        ),
      ],
    ),
    protocols: [CliCommunicationProtocol()],
  );

  print(await client.callTool('tools.greet', {'name': 'World'}));
  await client.close();
}
```

With `UtcpClient.fromJson`, pass `protocols: [CliCommunicationProtocol()]` and use
`"call_template_type": "cli"` in the configuration. A runnable example is in
`example/utcp_cli_example.dart`.

## Call templates

```json
{
  "call_template_type": "cli",
  "commands": [
    {"command": "cd UTCP_ARG_target_dir_UTCP_END", "append_to_final_output": false},
    {"command": "git status --porcelain"}
  ],
  "working_dir": "/tmp",
  "env_vars": {"GIT_AUTHOR_NAME": "UTCP Bot"},
  "inherit_env_vars": ["PATH", "HOME"]
}
```

- All `commands` run in order in one shell process: `/bin/bash -c` on macOS and Linux,
  `powershell.exe -NoProfile -Command` on Windows. `cd` and variables set by one command carry
  over to the next. A command must not be blank.
- `UTCP_ARG_<name>_UTCP_END` takes the tool argument `<name>`. Strings are passed as is, other
  values as JSON. A missing argument, or one containing a NUL character, fails the call.
- `$CMD_<i>_OUTPUT` holds the output (stdout and stderr) of command `i`.
- Only the last command's output is returned, unless commands set `append_to_final_output`.
  Output that starts with `{` or `[` and parses as JSON is returned decoded; anything else is
  returned as trimmed text. A failing command returns its error text rather than throwing.
- `working_dir` defaults to the current directory.
- Calls time out after 120 seconds and discovery after 60, and a script may write at most 10 MiB
  of output (`callTimeout`, `discoveryTimeout` and `maxOutputBytes` on
  `CliCommunicationProtocol`). A script over the limit is killed and the call fails.

## Windows (experimental)

On Windows the commands run in PowerShell. That path is untested: CI runs the bash tests on Linux
only, so treat Windows support as experimental.

## Security

- Tool arguments never become script text. Each placeholder is replaced by a reference to an
  environment variable that carries the value (`"$V"`, `${V}` inside double quotes, `'"$V"'`
  inside single quotes; `${env:V}` in PowerShell), with a random per-call name. The shell expands
  it after parsing the script, so the value is always one word, never glob-expanded, and never
  parsed as shell syntax, including inside `"$(...)"` and backticks. In PowerShell a placeholder
  inside single quotes is rejected. This matches the Python and TypeScript SDKs.
- Bash still evaluates a value used as a number as an arithmetic expression, and an array
  subscript in that expression runs command substitutions: with `n='a[$(rm -rf ~)]'`,
  `[[ "$n" -gt 3 ]]` runs `rm`. A placeholder is therefore rejected (the call fails) inside
  `$(( ))`, `(( ))` (including `for ((...))`), `$[ ]`, any `${...}`, an array subscript
  (`name[...]`, or `[...]=` in `name=(...)`), a `[[ ]]` that uses `-eq`, `-ne`, `-lt`, `-le`,
  `-gt`, `-ge` or `-v`, a `test -v`/`[ -v ]`, a `let` command, a `declare`/`typeset`/`local` with
  `-i`, and an assignment to a variable declared with `-i` anywhere in the command. The command
  checks also fire inside a `{ }` group or a function body, through the wrapper words `builtin`,
  `command`, `time`, `exec`, `nohup` and `env` and their options, and with a quoted or escaped
  command name (`'let'`, `\let`). Compare numbers with `[ ]` or `test`, which accept only
  integer literals, or pass the value to a program such as `expr`. The reference SDKs do not
  reject these contexts.
- The scanner models heredocs (`<<` and `<<-`, quoted and unquoted delimiters; `<<` in
  arithmetic is a shift) and `case` statements, so their bodies no longer desync the quoting of
  later placeholders. A placeholder in a quoted-delimiter heredoc body (`<<'EOF'`), where bash
  would not expand it, is rejected, as is a placeholder in a `case` statement inside a `$(...)` or
  backtick command substitution, which bash 3.2 cannot parse reliably. Bash 3.2 and 5.x also
  disagree on where a heredoc inside a command substitution ends (`EOF)`, a `)` or quote in the
  body), so a placeholder after such a heredoc is rejected.
- As defense in depth, independent of the scanner, an argument value with a substitution (`$(`,
  `${`, `$name` or a backtick) inside `[...]` is rejected, naming the argument: an array subscript
  is the one shape bash runs code from when it evaluates a value as a number. The values of one
  command are also checked joined, since two placeholders in one word can build the subscript
  together. The scanner cannot tell whether a value reaches arithmetic later (through a variable,
  a function or another program), so this check applies in every context. Text with a
  substitution outside brackets, such as ``See [docs](https://x) and run `make` ``, and JSON
  arrays such as `[1,2]` pass.
- These checks only see placeholders. A template must not carry a value into those contexts
  some other way: through a shell variable or command output (`n=UTCP_ARG_n_UTCP_END; (( n ))`,
  `$(( $(cat file) ))`), or a builtin that takes the value as a variable name (`read`, `unset`,
  `printf -v`). `eval`, `source`, `bash -c` and the like run the value as code.
- The commands themselves are trusted: never build a template from untrusted input.
- The host environment is not inherited. By default only `PATH`, `HOME`, `LANG`, `LC_ALL`,
  `LC_CTYPE`, `USER`, `LOGNAME`, `SHELL`, `TZ` and `TERM` (a Windows equivalent there) pass
  through; `inherit_env_vars` replaces that list, and `[]` passes nothing. `env_vars` are always
  set.
- Keep secrets out of `command`. `UtcpClient` substitutes `${VAR}` into the command text, which
  becomes the shell's command line, and any local user can read that with `ps`. Pass a secret in
  `env_vars` instead (`"env_vars": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}`) and let the program read
  it from its environment.
- A timeout, the output limit, cancelling a `callToolStreaming` subscription, and `close()` kill
  the shell and every process it started.

## Differences from the reference SDKs

- The Python and TypeScript SDKs run each bash command in its own subshell, so `exit`, `exec` or
  `set -e` ends only that command and the script goes on. Here the commands share one shell, as
  the spec requires (so `cd` and variables carry over), and such a command ends the script. The
  call then returns the outputs selected before it, followed by that command's own output, and
  later commands do not run. A script syntax error returns the shell's error text. A command may
  install a `trap '…' EXIT`; its output, printed as the shell exits after the script finished, is
  discarded.
- Bash placeholders in arithmetic contexts are rejected (see Security), and output is capped by
  `maxOutputBytes`.

## Known limitation

`UtcpClient` resolves `$NAME` and `${NAME}` placeholders as client variables in every call template
field before the protocol runs (as the Python and TypeScript clients do). Through a client, a
command referencing `$CMD_0_OUTPUT` or another shell variable therefore needs that variable to be
defined, or the call fails with `UtcpVariableNotFoundException`. Read shell variables in a way the
substitutor does not match, for example `"$(printenv NAME)"`.

## Packages

| Package | Transports |
| --- | --- |
| [`utcp`](https://pub.dev/packages/utcp) | Core client, `http` (with OpenAPI conversion), `sse`, `streamable_http`, `text` |
| [`utcp_mcp`](https://pub.dev/packages/utcp_mcp) | `mcp` (MCP servers over stdio and streamable HTTP) |
| [`utcp_cli`](https://pub.dev/packages/utcp_cli) | `cli` |
| [`utcp_file`](https://pub.dev/packages/utcp_file) | `file`, `.env` variable loader |
| [`utcp_socket`](https://pub.dev/packages/utcp_socket) | `tcp`, `udp` |
| [`utcp_websocket`](https://pub.dev/packages/utcp_websocket) | `websocket` |
