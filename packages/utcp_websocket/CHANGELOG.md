## Unreleased

- **Breaking:** `WebSocketCallTemplate.fromJson` rejects a `url` that is neither `wss://` nor `ws://` to a loopback address, as the Python reference does, so a document with one fails when the client is created. A host placeholder counts as remote: `ws://${HOST}:8765/ws` fails even with `HOST=localhost`; use `wss://`, a literal loopback host, or a whole-URL variable such as `${WS_URL}`.
- A URL variable that resolves to an insecure address, such as `${WS_URL}` set to `ws://evil.example/ws`, fails discovery with an unsuccessful `RegisterManualResult` and a call with a `UtcpSecurityException`. The rejection is both a `FormatException` and a `UtcpSecurityException`.

## 0.1.1

- Docs: package cross-links, badges and platform notes.

## 0.1.0

- `websocket` transport with string and object message templates, JSON/text/binary responses, and streaming calls.
- Pooled connections with serialized exchanges, subprotocols, keep-alive pings, handshake headers and auth.
- `wss://` or loopback `ws://` only, upgrade redirects refused, and remote manuals may not point tools at loopback.
- Runs on the web, without handshake headers.
- Calls that send `header_fields` use a connection of their own, closed after the call, instead of pooling one socket per distinct value.
- A call never receives a frame that arrived before it was sent, and unread frames are bounded (reading pauses at 16 frames or 4 MiB).
- `close()` aborts handshakes in progress, and calls after `close()` fail.
- `WebSocketCallTemplate.endpoints` lets the core remote-loopback rule cover WebSocket tools in manuals discovered over any transport; `rejectRemoteLoopbackWebSocketTools` is removed in favor of the core check.
- Errors and logs no longer include a WebSocket URL's query string or user info.
- `WebSocketCommunicationProtocol` takes an optional `connector`, for example to use in-memory channels.
- On the VM, paused reading stops reading the socket, so TCP flow control pushes back on the server instead of frames piling up in memory, and a message over 16 MiB fails the call.
- A call waiting for a pooled connection that other calls hold fails after its `timeout` instead of waiting indefinitely.
- Deregistering a manual aborts its connection still being opened instead of leaving it open in the pool.
- Closing a connection waits for the server's close frame, so the socket and keep-alive timer no longer outlive it.
- The README states which frames belong to which call, and what frames without a correlation id cannot guarantee.
