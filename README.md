# UTCP for Dart

[![pub package](https://img.shields.io/pub/v/utcp.svg)](https://pub.dev/packages/utcp)
[![CI](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/leehack/utcp_dart/actions/workflows/ci.yml)

Dart packages for the [Universal Tool Calling Protocol (UTCP)](https://github.com/universal-tool-calling-protocol/utcp-specification),
an open standard that lets AI agents and LLM apps discover tools and call them directly.

A provider publishes a manual that lists its tools and how to call each one. The client calls the
tool over its native protocol (HTTP, WebSocket, TCP, a CLI), with no wrapper server in between.
Existing MCP servers still work through `utcp_mcp`.

The core works in Flutter apps on mobile, desktop and web, and has no Flutter dependency.

## Quick start

```sh
dart pub add utcp
```

```dart
import 'package:utcp/utcp.dart';

Future<void> main() async {
  final client = await UtcpClient.create(
    config: UtcpClientConfig(
      variables: {'weather_API_KEY': 'my-key'},
      manualCallTemplates: [
        HttpCallTemplate(name: 'weather', url: 'https://api.example.com/utcp'),
      ],
    ),
  );

  final tools = await client.searchTools('current weather');
  final result = await client.callTool(tools.first.name, {'city': 'Seoul'});
  print(result);

  await client.close();
}
```

More in the [`utcp` README](packages/utcp/README.md), including a Flutter example and an
LLM tool-calling loop ([`claude_tool_use.dart`](packages/utcp/example/claude_tool_use.dart)).

## Packages

| Package | Transports |
| --- | --- |
| [`utcp`](https://pub.dev/packages/utcp) | Core client, `http` (with OpenAPI conversion), `sse`, `streamable_http`, `text` |
| [`utcp_mcp`](https://pub.dev/packages/utcp_mcp) | `mcp` (MCP servers over stdio and streamable HTTP) |
| [`utcp_cli`](https://pub.dev/packages/utcp_cli) | `cli` |
| [`utcp_file`](https://pub.dev/packages/utcp_file) | `file`, `.env` variable loader |
| [`utcp_socket`](https://pub.dev/packages/utcp_socket) | `tcp`, `udp` |
| [`utcp_websocket`](https://pub.dev/packages/utcp_websocket) | `websocket` |

## Platform support

| Package | Mobile and desktop (Dart VM, Flutter) | Web |
| --- | --- | --- |
| `utcp` | Yes | Yes |
| `utcp_websocket` | Yes | Yes (no handshake headers) |
| `utcp_mcp` | Yes | Streamable HTTP servers (stdio needs a native platform) |
| `utcp_cli` | Yes | No: browsers cannot spawn processes |
| `utcp_socket` | Yes | No: browsers cannot open raw sockets |
| `utcp_file` | Yes | No: browsers cannot read files by path |

## Spec compliance

| Package | UTCP spec version |
| --- | --- |
| `utcp` | 1.1.0 |
| `utcp_mcp` | 1.1.0 |
| `utcp_cli` | 1.1.0 |
| `utcp_file` | 1.1.0 |
| `utcp_socket` | 1.1.0 |
| `utcp_websocket` | 1.1.0 |

Manuals are written with `utcp_version` set to `utcpProtocolVersion`. The
[conformance suite](packages/utcp_conformance) parses and round-trips every UTCP document
in the spec and the reference SDKs. It was last verified against:

| Reference | Commit |
| --- | --- |
| [UTCP specification](https://github.com/universal-tool-calling-protocol/utcp-specification) | [`4a9ed93`](https://github.com/universal-tool-calling-protocol/utcp-specification/tree/4a9ed936a863a1f5d13ad8ef1b2b8a9783d459d6) |
| [python-utcp](https://github.com/universal-tool-calling-protocol/python-utcp) | [`bb8e2f6`](https://github.com/universal-tool-calling-protocol/python-utcp/tree/bb8e2f6f6f78f4f773ff383a4e065523b0b1297a) |
| [typescript-utcp](https://github.com/universal-tool-calling-protocol/typescript-utcp) | [`ea4902d`](https://github.com/universal-tool-calling-protocol/typescript-utcp/tree/ea4902d3bdae3880026cc9b3391a5f8895c9b1ad) |

## Links

- [UTCP specification](https://github.com/universal-tool-calling-protocol/utcp-specification)
- [Contributing](AGENTS.md)
- [License](LICENSE) (MPL-2.0)
