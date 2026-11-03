# utcp_socket

[![pub package](https://img.shields.io/pub/v/utcp_socket.svg)](https://pub.dev/packages/utcp_socket)
[![CI](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml)

TCP and UDP transports for the [UTCP](https://github.com/universal-tool-calling-protocol) Dart client
([`utcp`](https://pub.dev/packages/utcp)). Behavior follows the Python reference plugin
(`utcp-socket`). Requires `dart:io`, so it runs on the Dart VM and Flutter, not the web.

## Usage

```dart
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

Future<void> main() async {
  final client = await UtcpClient.fromJson(
    {
      'manual_call_templates': [
        {
          'name': 'calc',
          'call_template_type': 'tcp',
          'host': '127.0.0.1',
          'port': 9000,
          'framing_strategy': 'delimiter',
          'message_delimiter': r'\n',
        },
        {
          'name': 'sensors',
          'call_template_type': 'udp',
          'host': '127.0.0.1',
          'port': 9001,
        },
      ],
    },
    protocols: [TcpCommunicationProtocol(), UdpCommunicationProtocol()],
  );

  print(await client.callTool('calc.add', {'a': 2, 'b': 3}));
  await client.close();
}
```

A runnable example with local servers is in `example/utcp_socket_example.dart`.

## Discovery

Registering a manual sends `{"type": "utcp"}` (framed like any request) and expects a JSON object
with a `tools` array. A tool without a valid `tool_call_template` (or legacy `tool_provider`) is
called through the manual's own template; invalid tools are skipped. A response without `tools` is
an empty manual.

## Requests and responses

| Field | Default | Meaning |
| --- | --- | --- |
| `host`, `port` | required | Server address. |
| `request_data_format` | `json` | `json` sends the arguments as one object. `text` fills `request_data_template`, replacing `UTCP_ARG_<name>_UTCP_ARG` with each argument (strings as is, other values as JSON); without a template the values are joined by spaces. |
| `response_byte_format` | `utf-8` | Encoding of the response (`utf-8`, `ascii`, `latin1`, ...). `null` returns the raw bytes, as does a response that does not decode. |
| `timeout` | `30000` | Milliseconds. |

`auth` is rejected: raw sockets carry no credentials.

### TCP framing

One connection per request, closed on every path. `framing_strategy` selects how messages are
delimited:

| Strategy | Fields | Response |
| --- | --- | --- |
| `stream` (default) | `max_response_size` (65536) | Until the server closes, goes quiet for `timeout`, or `max_response_size` bytes. |
| `length_prefix` | `length_prefix_bytes` (1, 2, 4, 8; default 4), `length_prefix_endian` (`big`) | Requests and responses carry their byte length first. |
| `delimiter` | `message_delimiter` (`\x00`), `interpret_escape_sequences` (`true`) | Requests and responses end with the delimiter. Python escapes such as `\n` or `\x00` are interpreted unless disabled. |
| `fixed_length` | `fixed_message_length` (required) | Exactly that many bytes. |

`timeout` bounds the connect and each wait for data, as in the reference. Length-prefix,
delimiter and fixed-length responses larger than `max_response_size` fail.

### UDP

One request datagram per call. `number_of_response_datagrams` (default 1) datagrams are collected
and concatenated: the first may take `timeout`, each later one up to a second, after which the
datagrams received so far are returned. `0` sends without waiting. Datagrams from other addresses
are ignored, and requests are not retried.

## Security

A manual discovered from a non-loopback host may not point tools of any transport at a loopback
address, so a remote provider cannot aim requests at services on the agent's machine. The `tcp`
and `udp` templates list `tcp://host:port` / `udp://host:port` in `CallTemplate.endpoints`, so the
core rule also rejects loopback socket tools in a manual discovered over HTTP or any other
transport.

## Differences from the Python reference

- Arguments are substituted in one pass, so an argument value cannot introduce placeholders, and a
  `text` template that looks like JSON (starts with `{` or `[`) gets its string arguments
  JSON-escaped, as the WebSocket reference does.
- Non-string values in `text` requests are written as JSON (Python writes `str(value)`, e.g.
  `True`), and JSON is written compactly.
- Partial reads are reassembled for every framing, `max_response_size` limits every framing (not
  only `stream`), and the remote-manual loopback rule above is applied.
- Template errors (bad `length_prefix_bytes`, missing `fixed_message_length`, malformed delimiter
  escapes, negative datagram counts) fail when the template is parsed.

## Packages

| Package | Transports |
| --- | --- |
| [`utcp`](https://pub.dev/packages/utcp) | Core client, `http` (with OpenAPI conversion), `sse`, `streamable_http`, `text` |
| [`utcp_mcp`](https://pub.dev/packages/utcp_mcp) | `mcp` (MCP servers over stdio and streamable HTTP) |
| [`utcp_cli`](https://pub.dev/packages/utcp_cli) | `cli` |
| [`utcp_file`](https://pub.dev/packages/utcp_file) | `file`, `.env` variable loader |
| [`utcp_socket`](https://pub.dev/packages/utcp_socket) | `tcp`, `udp` |
| [`utcp_websocket`](https://pub.dev/packages/utcp_websocket) | `websocket` |
