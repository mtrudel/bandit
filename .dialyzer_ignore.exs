[
  {"lib/thousand_island/transports/ssl.ex", :unknown_type},
  {"deps/thousand_island/lib/thousand_island/handler.ex", :unmatched_return},
  # handle_connection/2 return type is extended and differs from behaviour it implements
  # it's not a problem because because InitialHandler is wrapped into DelegatingHandler,
  # but Dialyzer complains
  {"lib/bandit/initial_handler.ex", :callback_spec_type_mismatch},
  # unmatched_return check doesn't have much sense in the test support code
  {"test/support/simple_h2_client.ex", :unmatched_return},
  {"test/support/simple_http1_client.ex", :unmatched_return},
  {"test/support/simple_websocket_client.ex", :unmatched_return},
  {"test/support/telemetry_collector.ex", :unmatched_return},
]
