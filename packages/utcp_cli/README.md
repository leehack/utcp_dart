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
  over to the next.
- `UTCP_ARG_<name>_UTCP_END` takes the tool argument `<name>`. Strings are passed as is, other
  values as JSON. A missing argument fails the call.
- `$CMD_<i>_OUTPUT` holds the output (stdout and stderr) of command `i`.
- Only the last command's output is returned, unless commands set `append_to_final_output`.
  Output that starts with `{` or `[` and parses as JSON is returned decoded; anything else is
  returned as trimmed text. A failing command returns its error text rather than throwing.
- `working_dir` defaults to the current directory.
- Calls time out after 120 seconds and discovery after 60 (configurable on
  `CliCommunicationProtocol`).

## Security

- Tool arguments never become script text. Each placeholder is replaced by a reference to an
  environment variable that carries the value (`"$V"`, `${V}` inside double quotes, `'"$V"'`
  inside single quotes; `${env:V}` in PowerShell), with a random per-call name. The shell expands
  it after parsing the script, so an argument is always one word and cannot inject commands. In
  PowerShell a placeholder inside single quotes is rejected. This matches the Python and
  TypeScript SDKs.
- The commands themselves are trusted: never build a template from untrusted input.
- The host environment is not inherited. By default only `PATH`, `HOME`, `LANG`, `LC_ALL`,
  `LC_CTYPE`, `USER`, `LOGNAME`, `SHELL`, `TZ` and `TERM` (a Windows equivalent there) pass
  through; `inherit_env_vars` replaces that list, and `[]` passes nothing. `env_vars` are always
  set.
- A timeout, cancelling a `callToolStreaming` subscription, and `close()` kill the shell and every
  process it started.

## Known limitation

`UtcpClient` resolves `$NAME` and `${NAME}` placeholders as client variables in every call template
field before the protocol runs (as the Python and TypeScript clients do). Through a client, a
command referencing `$CMD_0_OUTPUT` or another shell variable therefore needs that variable to be
defined, or the call fails with `UtcpVariableNotFoundException`. Read shell variables in a way the
substitutor does not match, for example `"$(printenv NAME)"`.
