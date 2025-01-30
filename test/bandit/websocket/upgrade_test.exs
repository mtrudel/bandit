defmodule WebSocketUpgradeTest do
  use ExUnit.Case, async: true
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

    conn
    |> put_resp_header("x-plug-set-header", "itsaheader")
    |> Plug.Conn.upgrade_adapter(:websocket, {websock, :upgrade, connection_opts})
  end

  defmodule UpgradeWebSock do
    use NoopWebSock
    def init(opts), do: {:ok, opts}
  end

  defmodule UpgradeSendOnTerminateWebSock do
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
    test "upgrades to a {websock, websock_opts, conn_opts} tuple, respecting options", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, UpgradeSendOnTerminateWebSock, timeout: "250")

      SimpleWebSocketClient.send_text_frame(client, "")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)
      assert result == inspect([:upgrade, :init])

      # Ensure that the passed timeout was recognized
      then = System.monotonic_time(:millisecond)
      assert_receive :timeout, 500
      now = System.monotonic_time(:millisecond)
      assert_in_delta now, then + 250, 50
    end

    test "upgrade responses include headers set from the plug", context do
      client = SimpleWebSocketClient.tcp_client(context)

      assert {:ok,
              [
                "cache-control: max-age=0, private, must-revalidate",
                "x-plug-set-header: itsaheader"
              ]} = SimpleWebSocketClient.http1_handshake(client, UpgradeWebSock)
    end

    defmodule MyNoopWebSock do
      use NoopWebSock
    end

    test "emits HTTP telemetry on upgrade", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, MyNoopWebSock)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn),
               plug: {__MODULE__, []}
             }
    end
  end
end
