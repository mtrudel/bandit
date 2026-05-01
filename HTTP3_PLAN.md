# HTTP/3 Implementation Plan

## Overview
Add HTTP/3 support to Bandit using the [`quic`](https://hex.pm/packages/quic) hex package (v0.6.1,
a pure Erlang QUIC/RFC 9000 implementation). HTTP/3 uses QUIC over UDP as its transport, so it
cannot reuse ThousandIsland (TCP-only). This requires a parallel listener/handler stack alongside
the existing HTTP/1 & HTTP/2 stack.

## Key Technical Constraints
- **QUIC = UDP**: No ThousandIsland. Use `:quic_listener` + `:quic_connection` directly.
- **QPACK**: No existing Elixir/Erlang QPACK library exists. We implement static-table-only QPACK
  (RFC 9204). Static-table-only is valid per RFC and covers ~95% of real-world headers efficiently.
- **QUIC has integrated TLS 1.3**: Requires cert/key in `:quic_listener` options — same files as HTTPS.
- **HTTP/3 frame format**: Different from HTTP/2 (variable-length integer type + length + payload per RFC 9000 §16).
- **ALPN**: `"h3"` must be advertised in QUIC handshake.
- **Alt-Svc**: HTTP/1 & HTTP/2 responses should advertise HTTP/3 via `alt-svc` header.

## New Files

### `lib/bandit/http3/qpack.ex` (~400 lines)
Static-table-only QPACK encoder and decoder (RFC 9204).
- 99-entry static table as compile-time constant (RFC 9204 Appendix A)
- `encode_headers/1` → binary (for HEADERS frames)
- `decode_headers/1` → `[{name, value}]` (for incoming HEADERS frames)
- No dynamic table / encoder stream communication needed
- Encoding strategy: use static reference where possible, otherwise literal with name/value

### `lib/bandit/http3/frame.ex` (~150 lines)
HTTP/3 frame serialization/deserialization (RFC 9114 §7).
- Frame types: `DATA` (0x00), `HEADERS` (0x01), `SETTINGS` (0x04), `GOAWAY` (0x07)
- Wire format: varint type, varint length, payload
- `serialize/1` → iodata
- `deserialize/1` → `{:ok, frame, rest}` | `{:more, rest}` | `{:error, reason}`
- Variable-length integer encoding per RFC 9000 §16

### `lib/bandit/http3/stream.ex` (~300 lines)
HTTP/3 stream struct implementing `Bandit.HTTPTransport` protocol.
- Struct: `%{connection_pid, stream_id, quic_conn_ref, state, buffer, read_timeout}`
- `read_headers/1`: receives `{:bandit_h3, :headers, headers}` from connection process
- `read_data/2`: receives `{:bandit_h3, :data, data, fin}` messages
- `send_headers/4`: encodes QPACK, sends HEADERS frame via `GenServer.call(connection_pid, {:send_headers, ...})`
- `send_data/3`: sends DATA frame via `GenServer.call(connection_pid, {:send_data, ...})`
- `sendfile/4`: reads file and sends as DATA frames (no OS sendfile for UDP)
- `version/1`: returns `:"HTTP/3"`
- `ssl_data/1`: returns QUIC TLS info via `GenServer.call(connection_pid, :ssl_data)`
- `supported_upgrade?/2`: returns `false` (no WebSocket over HTTP/3 in initial impl)
- `send_on_error/2`: sends error response then closes stream

### `lib/bandit/http3/stream_process.ex` (~30 lines)
Identical pattern to `Bandit.HTTP2.StreamProcess`:
- `GenServer` with `restart: :temporary`
- `init/1` → `{:ok, state, {:continue, :start_stream}}`
- `handle_continue(:start_stream, ...)` → calls `Bandit.Pipeline.run/5` then stops

### `lib/bandit/http3/connection.ex` (~250 lines)
HTTP/3 connection state (a plain struct managed by Handler, not a process itself).
- Struct: `%{plug, opts, streams, local_settings, peer_data, control_stream_id, qpack_state}`
- `init/3`: opens unidirectional control stream, sends SETTINGS frame on it
- `handle_stream_opened/3`: routes new streams (control vs request vs QPACK)
- `handle_stream_data/4`: routes data to correct stream process (or buffer for control stream)
- `handle_control_frame/2`: processes SETTINGS, GOAWAY from client control stream
- `stream_terminated/2`: removes terminated stream from map

### `lib/bandit/http3/handler.ex` (~200 lines)
GenServer managing one QUIC connection. Receives `:quic_connection` messages.
- Started by `Bandit.HTTP3.Listener` via `:quic_listener`'s `connection_handler` callback
- Traps exits (owns stream processes)
- Handles `{:quic, conn_ref, {:connected, info}}` → initialize connection state
- Handles `{:quic, conn_ref, {:stream_opened, stream_id}}` → new stream
- Handles `{:quic, conn_ref, {:stream_data, stream_id, data, fin}}` → route data
- Handles `{:quic, conn_ref, {:closed, reason}}` → terminate
- `handle_call({:send_headers, ...})` → encode QPACK, wrap in HEADERS frame, send via `:quic_connection.send_data/4`
- `handle_call({:send_data, ...})` → wrap in DATA frame, send via `:quic_connection.send_data/4`
- `handle_info({:EXIT, pid, _})` → call `Connection.stream_terminated/2`

### `lib/bandit/http3/listener.ex` (~100 lines)
GenServer wrapping `:quic_listener`.
- `start_link/1` with cert (DER binary), key, port, plug, opts
- `init/1` → calls `:quic_listener.start_link(port, opts)` with `connection_handler` callback
- Callback: `fn conn_pid, conn_ref -> {:ok, pid} = Handler.start_link(conn_pid, conn_ref, ...); {:ok, pid} end`

## Files to Modify

### `mix.exs`
```elixir
{:quic, "~> 0.6"}
```

### `lib/bandit.ex`
- Add `http_3_options` type definition (port, enabled)
- In `start_link/1`: if `http_3_options: [enabled: true]` and scheme is `:https`, also start `Bandit.HTTP3.Listener`

## Architecture Flow

```
Bandit.start_link(scheme: :https, http_3_options: [enabled: true, port: 4433])
    |
    +-- ThousandIsland (HTTP/1 + HTTP/2, TCP/TLS port 4433)
    |
    +-- Bandit.HTTP3.Listener (QUIC, UDP port 4433)
              |
              | (quic_listener connection_handler callback)
              v
        Bandit.HTTP3.Handler (GenServer, 1 per QUIC connection)
              |
              | {:quic, ref, {:stream_opened, id}}  [bidirectional = request stream]
              v
        Bandit.HTTP3.StreamProcess (GenServer, 1 per HTTP/3 request)
              |
              | Bandit.Pipeline.run(stream, plug, ...)
              v
        Bandit.HTTP3.Stream (implements Bandit.HTTPTransport)
              |
              v
        User's Plug application
```

## QPACK Static Table Strategy
Implement static-table-only encoding:
- **Decoder**: Check index prefix bits. Static reference → look up 99-entry table. Literal → read name/value from wire.
- **Encoder**: Try to find `{name, value}` in static table → emit indexed representation. Otherwise, try name match → emit literal with name index. Otherwise, emit full literal (no indexing).
- The 99-entry RFC 9204 Appendix A table covers `:method`, `:path`, `:scheme`, `:authority`, `:status`, and ~30 common header names + values.

## Configuration API
```elixir
Bandit.start_link(
  scheme: :https,
  certfile: "priv/cert.pem",
  keyfile: "priv/key.pem",
  plug: MyPlug,
  http_3_options: [
    enabled: true,
    port: 4433   # UDP port (defaults to same as TCP port)
  ]
)
```

## Verification
1. `mix deps.get` — adds quic library
2. `mix compile` — all new modules compile cleanly
3. Start server: `Bandit.start_link(scheme: :https, http_3_options: [enabled: true], plug: MyPlug)`
4. Test: `curl --http3 https://localhost:4433/`
5. Check `alt-svc: h3=":4433"` in HTTP/1.1 / HTTP/2 responses
6. `mix test` — existing tests unaffected

## Limitations of Initial Implementation
- **Static QPACK only**: No dynamic table compression. Valid per RFC, less efficient.
- **No WebSocket over HTTP/3**: `supported_upgrade?/2` returns false
- **No HTTP/3 server push**: Not implemented (deprecated in practice)
- **No 0-RTT**: QUIC 0-RTT session resumption not implemented
