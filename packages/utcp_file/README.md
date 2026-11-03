# utcp_file

The `file` transport and the `.env` variable loader for the
[UTCP](https://github.com/universal-tool-calling-protocol) Dart client
([`utcp`](https://pub.dev/packages/utcp)).

## Usage

```dart
import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

Future<void> main() async {
  // Lets `load_variables_from` use `"variable_loader_type": "dotenv"`.
  DotEnvVariableLoader.register();

  final client = await UtcpClient.fromJson(
    {
      'load_variables_from': [
        {'variable_loader_type': 'dotenv', 'env_file_path': '.env'},
      ],
      'manual_call_templates': [
        {'name': 'local', 'call_template_type': 'file', 'file_path': 'tools.yaml'},
      ],
    },
    protocols: [FileCommunicationProtocol()],
  );

  print(await client.getTools());
  await client.close();
}
```

A runnable example is in `example/utcp_file_example.dart`. Without JSON configuration, pass
`FileCallTemplate(name: 'local', filePath: 'tools.yaml')` and `DotEnvVariableLoader('.env')`
to `UtcpClientConfig` directly.

## File call templates

```json
{"call_template_type": "file", "file_path": "manuals/tools.yaml"}
```

- Discovery reads the file as a UTCP manual or an OpenAPI 2.0/3.x document: `.yaml` and `.yml`
  files as YAML, everything else as JSON. OpenAPI documents are converted with `utcp`'s
  `OpenApiConverter`, applying `auth_tools`. As in the Python SDK, a file counts as a remote
  origin, so its servers may not point at loopback addresses. Relative paths resolve against `FileCommunicationProtocol(rootDir: ...)`, or the current
  directory.
- A tool call with a `file` template returns the text of its file.

## `.env` variable loader

`DotEnvVariableLoader` (`variable_loader_type: dotenv`, `env_file_path`) reads the file on every
lookup; a missing file defines nothing. Relative paths resolve against the current directory. The
format follows python-dotenv, which the UTCP Python SDK uses:

```sh
# Comments and blank lines are skipped.
export API_KEY=abc123          # `export` is ignored; so is a comment after whitespace
URL=https://example.com/#top   # a `#` without whitespace before it is part of the value
GREETING="Hello\nWorld"        # double quotes unescape \n, \t, \" and friends
RAW='C:\path'                  # single quotes unescape only \\ and \'
CERT="-----BEGIN-----
...
-----END-----"                 # quoted values may span lines
ENDPOINT=${URL}api/v1          # ${NAME} and ${NAME:-default} expand earlier values, then the environment
```
