defmodule Bandit.SochetHeadersTest do
  use ExUnit.Case, async: true

  test "iodata_empty?" do
    assert Bandit.SocketHelpers.iodata_empty?([])
    assert Bandit.SocketHelpers.iodata_empty?("")
    assert Bandit.SocketHelpers.iodata_empty?([["", []] | ""])

    refute Bandit.SocketHelpers.iodata_empty?([1])
    refute Bandit.SocketHelpers.iodata_empty?("1")
    refute Bandit.SocketHelpers.iodata_empty?([["", []] | "ok"])
  end

  describe "when the client has already reset the connection" do
    # Thousand Island captures the peername when it accepts a connection, so neither of these
    # needs the (by now failing) live lookup on the underlying socket
    setup do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, listen_port} = :inet.port(listener)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", listen_port, [:binary, active: false, linger: {true, 0}])

      {:ok, client_port} = :inet.port(client)
      {:ok, accepted} = :gen_tcp.accept(listener)
      peername = {{127, 0, 0, 1}, client_port}

      handler_config = %ThousandIsland.HandlerConfig{
        handler_module: nil,
        transport_module: ThousandIsland.Transports.TCP,
        read_timeout: 1000,
        handshake_timeout: 1000,
        silent_terminate_on_error: false
      }

      socket = ThousandIsland.Socket.new(accepted, peername, handler_config, nil)

      # linger: {true, 0} makes this send an RST. Wait for it to land, so that we know a live
      # lookup would really fail
      :gen_tcp.close(client)
      assert {:error, _reason} = wait_for_peername_failure(accepted, 200)

      on_exit(fn ->
        :gen_tcp.close(accepted)
        :gen_tcp.close(listener)
      end)

      %{socket: socket, client_port: client_port}
    end

    test "conn_data/1 still returns the peer address", %{socket: socket} do
      assert Bandit.SocketHelpers.conn_data(socket) == {false, {127, 0, 0, 1}}
    end

    test "peer_data/1 still returns the peer address and port", context do
      assert Bandit.SocketHelpers.peer_data(context.socket) ==
               %{address: {127, 0, 0, 1}, port: context.client_port, ssl_cert: nil}
    end

    defp wait_for_peername_failure(raw_socket, retries) do
      case :inet.peername(raw_socket) do
        {:ok, _} when retries > 0 ->
          Process.sleep(5)
          wait_for_peername_failure(raw_socket, retries - 1)

        result ->
          result
      end
    end
  end
end
