# HTTP/3 Bug Fixes

Bugs fixed while bringing HTTP/3 end-to-end in Bandit (QUIC handshake → request → response).

---

## `deps/quic/src/quic_connection.erl`

### 1. Server role guard in `handle_packet_loop`
`inet:setopts` was called on the shared listener UDP socket from the server's
connection process, corrupting socket state for other connections.

**Fix:** Skip `inet:setopts` when `role = server`.

---

### 2. DCID update in `decode_initial_packet`
On the first Initial packet from the client, the server's `dcid` field was not
being updated to the client's SCID. Subsequent packets were sent to the wrong
destination connection ID.

**Fix:** Server sets `state.dcid = client_scid` on first Initial packet.

---

### 3. Transport parameter key `scid` → `initial_scid`
When parsing the client's QUIC transport parameters from the ClientHello,
the code looked for the key `scid` but ngtcp2/curl sends `initial_scid`.

**Fix:** Use `initial_scid` as the map key.

---

### 4. Missing `original_destination_connection_id` transport parameter
RFC 9000 §7.3 requires the server to echo the `original_destination_connection_id`
(the DCID from the client's first Initial packet) in its transport parameters.
ngtcp2 treats its absence as a `TRANSPORT_PARAMETER_ERROR` and closes the connection.

**Fix:** Added `original_dcid => State#state.original_dcid` to the server's
`TransportParams` map in `send_server_handshake_flight`.

---

### 5. State machine missing `TLS_AWAITING_CLIENT_FINISHED` → `handshaking`
After processing the ClientHello, the server sets `tls_state = TLS_AWAITING_CLIENT_FINISHED`
but `check_state_transition` had no case for this, so the state stayed `idle`.
When the client Finished then arrived, the server jumped directly `idle → connected`,
skipping the `connected(enter, handshaking, ...)` callback entirely — so the Handler
never received the `{quic, Ref, {connected, Info}}` message.

**Fix:** Added `{idle, ?TLS_AWAITING_CLIENT_FINISHED, _} -> {next_state, handshaking, State}`.

---

### 6. `connected(enter, ...)` only matched `handshaking` as old state
A defensive issue: the enter callback pattern matched only `handshaking` as the
previous state. With the state machine in flux, this was fragile.

**Fix:** Changed to `connected(enter, _OldState, ...)` to match any prior state.

---

### 7. Wrong AEAD key direction in `decrypt_app_packet_continue`
`decrypt_app_packet_continue` always destructured the key pair as
`{_, ServerDecryptKeys} = DecryptKeys` and used `ServerDecryptKeys` for AEAD
decryption. This works for the client (decrypting server packets with server
keys) but is wrong for the server: incoming packets from the client are
encrypted with `ClientKeys` (the first element of the pair). All 1-RTT packets
from curl failed to decrypt with `bad_tag`.

**Fix:** Select the correct directional key based on role:
```erlang
AEAD_Keys = case State1#state.role of
    server -> ClientDecryptKeys;
    client -> ServerDecryptKeys
end,
```

---

## `lib/bandit/http3/handler.ex`

### 8. `build_quic_fns` used `:quic_connection` module with a reference
`conn_ref` is a `reference()`, but `:quic_connection.send_data/4` and
`:quic_connection.open_unidirectional_stream/1` require a PID. The `:quic`
module's public API does `lookup_conn` internally and accepts references.

Also, `fin: fin` was passing a keyword list where a boolean was expected.

**Fix:** Changed to `:quic.send_data(conn_ref, stream_id, data, fin)` and
`:quic.open_unidirectional_stream(conn_ref)`.

---

## `lib/bandit/http3/connection.ex`

### 9. `stream_opened` event never fired; streams never spawned
`handle_stream_data` assumed a `stream_opened` event would precede data, and
routed unknown stream IDs to `handle_unidirectional_data`. But the `:quic`
library never sends a `stream_opened` event — only `stream_data`. Request
streams (stream_id `band` 0x3 == 0) had no StreamProcess spawned, so HTTP/3
requests were silently discarded.

**Fix:** `handle_stream_data` now dispatches on `band(stream_id, 0x3)` first,
spawning a StreamProcess on first data arrival for client-initiated bidirectional
streams. Added `handler_pid` as a 5th parameter (passed as `self()` from the Handler).

---

## `lib/bandit/http3/qpack.ex`

### 10. Huffman decoding not supported
`decode_string` returned `{:error, :huffman_not_supported}` for any
Huffman-encoded string literal. curl Huffman-encodes all header values by
default, so every request header block failed to decode.

**Fix:** Used `HPAX.Huffman.decode/1` (already a project dependency). The
function returns `binary()` directly and throws `{:hpax, reason}` on invalid
input, so calls are wrapped in `try/catch`.
