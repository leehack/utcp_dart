## 0.2.0

- **Breaking:** a `text` request without a template writes non-string arguments as Python's `str()` does instead of as JSON, matching the Python SDK: `{n: 1, flag: true}` now sends `1 True` instead of `1 true`, and `null` and lists become `None` and `['a', 1]`.
- Delimiters accept `\N{name}` escapes for the names and aliases of Basic Latin, Latin-1 Supplement, General Punctuation and U+FEFF (such as `\N{NUL}` or `\N{RECORD SEPARATOR}`); other names fail when the template is parsed.
- `response_byte_format` accepts Python's encoding names and aliases, such as `latin-1`, `utf-16-le`, `cp1252`, `us` and `iso-ir-100`, ignoring case and punctuation. An unsupported name fails when the template is parsed instead of after the request is sent. An unsupported name fails when the template is parsed instead of after the request is sent.
- `max_response_size` applies only to `stream` framing, as in the Python SDK. Length-prefix, delimiter and fixed-length responses are capped by the new `TcpCommunicationProtocol(maxFrameBytes: ...)`, 10 MiB by default.

## 0.1.1

- Docs: package cross-links, badges and platform notes.

## 0.1.0

- `tcp` transport with length-prefix, delimiter, fixed-length and stream framing.
- `udp` transport with multi-datagram responses and fire-and-forget requests.
- JSON or templated text requests, and text or raw-bytes responses.
- Manual discovery over both transports; a remote manual may not point tools at loopback.
- `max_response_size` also limits delimiter frames whose delimiter is found and fixed-length frames.
- `TcpCallTemplate` and `UdpCallTemplate` list their address in `endpoints`, so loopback socket tools are rejected in remote manuals discovered over any transport.
