[
  {"lib/thousand_island/transports/ssl.ex", :unknown_type},
  {"deps/thousand_island/lib/thousand_island/handler.ex", :unmatched_return},
  # handle_connection/2 return type is extended and differs from behaviour it implements
  # it's not a problem because because InitialHandler is wrapped into DelegatingHandler,
  # but Dialyzer complains
  {"lib/bandit/initial_handler.ex", :callback_spec_type_mismatch},
  # HTTP/2 and WebSocket frame sends are fire-and-forget; send errors surface via
  # the socket closing/erroring out, which is handled elsewhere in the connection lifecycle
  {"lib/bandit/http2/connection.ex", :unmatched_return},
  {"lib/bandit/http2/handler.ex", :unmatched_return},
  {"lib/bandit/websocket/connection.ex", :unmatched_return},
  {"lib/bandit/websocket/socket.ex", :unmatched_return},
  # The stream process always stops right after running the pipeline regardless of
  # outcome, and errors/responses are already handled within Pipeline.run/5 itself
  {"lib/bandit/http2/stream_process.ex", :unmatched_return},
  # :already_exists can't happen here; each call attaches with a fresh, unique self() id
  {"lib/bandit/trace.ex", :unmatched_return},
  # unmatched_return check doesn't have much sense in the test support code
  {"test/support/simple_h2_client.ex", :unmatched_return},
  {"test/support/simple_http1_client.ex", :unmatched_return},
  {"test/support/simple_websocket_client.ex", :unmatched_return},
  {"test/support/telemetry_collector.ex", :unmatched_return},
]
