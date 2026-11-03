# utcp_websocket

WebSocket transport for the [UTCP](https://github.com/universal-tool-calling-protocol) Dart client
([`utcp`](https://pub.dev/packages/utcp)). Behavior follows the Python reference plugin
(`utcp-websocket`). Runs on the Dart VM, Flutter and the web; handshake headers, and so header-based
auth, are VM-only.

## Usage

```dart
import 'package:utcp/utcp.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

Future<void> main() async {
  final client = await UtcpClient.fromJson(
    {
      'variables': {'stocks_API_KEY': 'my-key'},
      'manual_call_templates': [
        {
          'name': 'stocks',
          'call_template_type': 'websocket',
          'url': 'wss://stream.example.com/ws',
          'auth': {
            'auth_type': 'api_key',
            'api_key': r'${API_KEY}',
            'var_name': 'Authorization',
          },
        },
      ],
    },
    protocols: [WebSocketCommunicationProtocol()],
  );

  print(await client.callTool('stocks.quote', {'symbol': 'AAPL'}));
  await client.close();
}
```

A runnable example with a local server is in `example/utcp_websocket_example.dart`.

## Call template

| Field | Default | Meaning |
| --- | --- | --- |
| `url` | required | `wss://`, or `ws://` to a loopback address. |
| `message` | `null` | String or object template with `UTCP_ARG_<name>_UTCP_ARG` placeholders. Without one, the arguments are sent as one JSON object. |
| `response_format` | `null` | `json` parses text responses (falling back to the text); `text`, `raw` and `null` return them as received. Binary frames are returned as bytes. |
| `protocol` | `null` | Subprotocol requested in the handshake. |
| `keep_alive` | `true` | Ping the pooled connection every 30 seconds (VM only). |
| `timeout` | `30` | Seconds, for connecting, for a response, and for a whole streamed call. |
| `headers` | `{}` | Static handshake headers. |
| `header_fields` | `[]` | Arguments sent as handshake headers instead of in the message. |
| `auth` | `null` | `api_key` (header, query or cookie), `basic`, `oauth2` or `oauth2_user`. |

In a string template, string arguments are inserted as is and other values as JSON; when the
template looks like JSON (starts with `{` or `[`) string arguments are JSON-escaped so they cannot
inject fields. Object templates are substituted leaf by leaf, then encoded.

## Exchanges

- **Discovery** sends `{"type": "utcp"}` and waits for a text frame with a JSON object containing
  `tools`, skipping other frames.
- **Tool calls** send one text frame and return the next frame received.
- **Streaming calls** yield frames until `{"type": "stream_end"}` or the server closes.
  `{"type": "tool_response", "result": ...}` yields `result`, `{"type": "tool_error", "error": ...}`
  fails the call, and frames with a `request_id` are skipped.

Connections are pooled per handshake (URL, subprotocol, headers, auth and header-field values) and
stay open until the manual is deregistered or the protocol is closed. Frames carry no correlation
id, so exchanges on one connection run one at a time, and a connection whose exchange times out or
is cancelled is closed instead of reused.

## Security

The same rules as the core HTTP transport:

- `wss://` anywhere; plain `ws://` only to `localhost`, `127.0.0.0/8` or `::1`
  (`isSecureWebSocketUrl`, `ensureSecureWebSocketUrl`).
- A redirect of the upgrade request is never followed: it would carry the handshake headers to a
  host the URL check never saw. (Dart's `WebSocket.connect` follows them, so the VM handshake is
  done by this package.)
- OAuth2 tokens are fetched through `HttpTransport`, with its HTTPS and redirect rules.
- A manual discovered from a remote origin may not point WebSocket or HTTP tools, or their OAuth2
  token URLs, at loopback.

## Web

Browsers cannot send handshake headers, so on the web a template that needs them (static
`headers`, `header_fields`, header or cookie API keys, `basic`, `oauth2`) fails with a
`UtcpException`. API keys with `"location": "query"` work everywhere. `keep_alive` pings are not
available.

## Differences from the Python reference

- Exchanges on a pooled connection are serialized, and a timed-out or cancelled connection is
  closed, so a late answer is never returned to the next call.
- A tool call fails when the server closes before answering (Python returns `None`).
- `header_fields` are sent as handshake headers (the reference declares but ignores them), and
  connections are pooled per handshake rather than per manual name and URL.
- Arguments are substituted in one pass, and JSON is written compactly.
- Binary frames are yielded by streaming calls (the reference drops them).
