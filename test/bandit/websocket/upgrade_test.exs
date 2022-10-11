defmodule WebSocketUpgradeTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    conn
    |> Bandit.WebSocket.Handshake.handshake?()
    |> case do
      true ->
        sock = conn.query_params["sock"] |> String.to_atom()

        case conn.query_params["timeout"] do
          nil ->
            Plug.Conn.upgrade_adapter(conn, :websocket, {sock, :upgrade})

          timeout ->
            timeout = String.to_integer(timeout)
            Plug.Conn.upgrade_adapter(conn, :websocket, {sock, :upgrade, timeout: timeout})
        end

      false ->
        Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  defmodule UpgradeSock do
    use NoopSock
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
    test "upgrades to a {sock, sock_opts} tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, UpgradeSock)

      SimpleWebSocketClient.send_text_frame(client, "")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)

      assert result == inspect([:upgrade, :init])
    end

    @tag capture_log: true
    test "upgrades to a {sock, sock_opts, conn_opts} tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, UpgradeSock, timeout: "250")

      SimpleWebSocketClient.send_text_frame(client, "")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)
      assert result == inspect([:upgrade, :init])

      # Ensure that the passed timeout was recognized
      then = System.monotonic_time(:millisecond)
      assert_receive :timeout, 500
      now = System.monotonic_time(:millisecond)
      assert_in_delta now, then + 250, 50
    end
  end
end
