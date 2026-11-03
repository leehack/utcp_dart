## Unreleased

- Docs: package cross-links, badges and platform notes.

## 0.1.0

- `tcp` transport with length-prefix, delimiter, fixed-length and stream framing.
- `udp` transport with multi-datagram responses and fire-and-forget requests.
- JSON or templated text requests, and text or raw-bytes responses.
- Manual discovery over both transports; a remote manual may not point tools at loopback.
- `max_response_size` also limits delimiter frames whose delimiter is found and fixed-length frames.
- `TcpCallTemplate` and `UdpCallTemplate` list their address in `endpoints`, so loopback socket tools are rejected in remote manuals discovered over any transport.
