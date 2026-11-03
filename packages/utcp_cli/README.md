# utcp_cli

The `cli` transport for the [UTCP](https://github.com/universal-tool-calling-protocol) Dart client
([`utcp`](https://pub.dev/packages/utcp)). A manual is discovered by running commands that print a
UTCP manual, and each tool call runs the tool's commands with its arguments.

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
  `name[...]`, a `[[ ]]` that uses `-eq`, `-ne`, `-lt`, `-le`, `-gt` or `-ge`, a `let` command,
  and a `declare`/`typeset`/`local` with `-i`. Compare numbers with `[ ]` or `test`, which accept
  only integer literals, or pass the value to a program such as `expr`. The reference SDKs do not
  reject these contexts.
- These checks only see placeholders. A template must not carry a value into those contexts
  some other way: through a shell variable or command output (`n=UTCP_ARG_n_UTCP_END; (( n ))`,
  `$(( $(cat file) ))`), a variable declared integer earlier, or a builtin that takes the value as
  a variable name (`read`, `unset`, `printf -v`, `[[ -v ]]`). `eval`, `source`, `bash -c` and the
  like run the value as code.
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
  `set -e` ends only that command and the script goes on. Here the commands share one shell (so
  `cd` and variables carry over), and a command that ends it would leave the call without output.
  Such a call fails instead, with the shell's exit code and error; a script syntax error fails the
  same way. Return a status with `false` or `(exit 3)` rather than `exit`.
- Bash placeholders in arithmetic contexts are rejected (see Security), and output is capped by
  `maxOutputBytes`.

## Known limitation

`UtcpClient` resolves `$NAME` and `${NAME}` placeholders as client variables in every call template
field before the protocol runs (as the Python and TypeScript clients do). Through a client, a
command referencing `$CMD_0_OUTPUT` or another shell variable therefore needs that variable to be
defined, or the call fails with `UtcpVariableNotFoundException`. Read shell variables in a way the
substitutor does not match, for example `"$(printenv NAME)"`.
