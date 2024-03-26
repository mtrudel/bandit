defmodule WebSocketUpgradeTest do
  # False due to log & telemetry capture
  use ExUnit.Case, async: false
  use ServerHelpers
  use Machete

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    websock = conn.query_params["websock"] |> String.to_atom()

    connection_opts =
      case conn.query_params["timeout"] do
        nil -> []
        timeout -> [timeout: String.to_integer(timeout)]
      end

    Plug.Conn.upgrade_adapter(conn, :websocket, {websock, :upgrade, connection_opts})
  end

  defmodule UpgradeWebSock do
    use NoopWebSock
    def init(opts), do: {:ok, [opts, :init]}
    def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    def terminate(reason, _state), do: WebSocketUpgradeTest.send(reason)
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  def send(msg), do: send(__MODULE__, msg)

  describe "upgrade support" do
    @tag capture_log: true
    test "upgrades to a {websock, websock_opts, conn_opts} tuple, respecting options", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, UpgradeWebSock, timeout: "250")

      SimpleWebSocketClient.send_text_frame(client, "")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)
      assert result == inspect([:upgrade, :init])

      # Ensure that the passed timeout was recognized
      then = System.monotonic_time(:millisecond)
      assert_receive :timeout, 500
      now = System.monotonic_time(:millisecond)
      assert_in_delta now, then + 250, 50
    end

    defmodule MyNoopWebSock do
      use NoopWebSock
    end

    test "emits HTTP telemetry on upgrade", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, MyNoopWebSock)

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  req_header_end_time: integer(),
                  resp_body_bytes: 0,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  conn: struct_like(Plug.Conn, [])
                }}
             ]
    end
  end
end
