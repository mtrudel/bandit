defmodule WebSocketProtocolTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Bandit.WebSocket.Handshake.valid_upgrade?(conn) do
      true ->
        sock = conn.query_params["sock"] |> String.to_atom()
        Plug.Conn.upgrade_adapter(conn, :websocket, {sock, conn.params, []})

      false ->
        Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  # These socks are used throughout these tests, so declare them top-level
  defmodule EchoSock do
    use NoopSock
    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    def handle_control({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
  end

  defmodule TerminateSock do
    use NoopSock
    def terminate(reason, _state), do: WebSocketProtocolTest.send(reason)
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  def send(msg), do: send(__MODULE__, msg)

  describe "packet-level frame splitting / merging" do
    test "it should handle cases where the frames arrives in small chunks", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      # Send text frame one byte at a time
      (<<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK")
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(1), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> :gen_tcp.send(client, byte) end)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "it should handle cases where a full and partial frame arrive in the same packet",
         context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      # Send one and a half frames
      :gen_tcp.send(client, <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK" <> <<8::4, 1::4>>)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}

      # Now send the rest of the second frame
      :gen_tcp.send(client, <<1::1, 2::7, 0::32>> <> "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      # Send two text frames at once one byte at a time
      :gen_tcp.send(
        client,
        <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK" <> <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK"
      )

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end
  end

  describe "s/m/l frame sizes" do
    test "small (7 bit) frames are received properly", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "mid-sized (16 bit) frames are received properly", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      payload = String.duplicate("a", 1_000)
      SimpleWebSocketClient.send_text_frame(client, payload)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end

    test "large-sized (64 bit) frames are received properly", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      payload = String.duplicate("a", 100_000)
      SimpleWebSocketClient.send_text_frame(client, payload)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end
  end

  describe "frame fragmentation" do
    test "handle_in is called once when fragmented text frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      payload = String.duplicate("a", 1_000)
      SimpleWebSocketClient.send_text_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, expected_payload}
    end

    test "handle_in is called once when fragmented binary frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      payload = String.duplicate("a", 1_000)
      SimpleWebSocketClient.send_binary_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, expected_payload}
    end
  end

  describe "ping frames" do
    test "send a pong per RFC6455§5.5.2", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}
    end

    test "are processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)
      SimpleWebSocketClient.send_ping_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}

      SimpleWebSocketClient.send_continuation_frame(client, "CD")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "ABCD"}
    end
  end

  describe "pong frames" do
    test "are processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoSock)

      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)
      SimpleWebSocketClient.send_pong_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}

      SimpleWebSocketClient.send_continuation_frame(client, "CD")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "ABCD"}
    end
  end

  describe "server-side connection close" do
    defmodule ServerSideCloseSock do
      use NoopSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    test "server does a proper shutdown handshake when closing a connection", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, ServerSideCloseSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Get the sock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "normal")

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}

      # Wait a bit and validate that the server is still very much alive
      Process.sleep(100)
      assert Process.alive?(pid)

      # Now send our half of the handshake and verify that the server has shut down
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)
      Process.sleep(100)
      refute Process.alive?(pid)

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "client-side connection close" do
    defmodule ClientSideCloseSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    test "returns a corresponding connection close frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, ClientSideCloseSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Close the connection from the client
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      # Now ensure that we see the server's half of the shutdown handshake
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "client closes are are processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, ClientSideCloseSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Note that we don't expect this to send back a pid since it won't make it to the Sock
      SimpleWebSocketClient.send_text_frame(client, "whoami", 0x0)

      # Close the connection from the client
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      # Now ensure that we see the server's half of the shutdown handshake
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "server sends a 1002 on an unexpected continuation frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_continuation_frame(client, <<1, 2, 3>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received unexpected continuation frame (RFC6455§5.4)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 on a text frame during continuation", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_text_frame(client, <<1, 2, 3>>, 0x0)
      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_text_frame(client, <<1, 2, 3>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received unexpected text frame (RFC6455§5.4)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 on a binary frame during continuation", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_binary_frame(client, <<1, 2, 3>>, 0x0)
      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_binary_frame(client, <<1, 2, 3>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received unexpected binary frame (RFC6455§5.4)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on a non UTF-8 text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8, 0x82::8, 0x28::8>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received non UTF-8 text frame (RFC6455§8.1)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on fragmented non UTF-8 text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8>>, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, <<0x82::8, 0x28::8>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received non UTF-8 text frame (RFC6455§8.1)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "timeout conditions" do
    @tag capture_log: true
    test "server sends a 1002 if no frames sent at all", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive :timeout, 1500

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 on timeout between frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive :timeout, 1500

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule TimeoutCloseSock do
      use NoopSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    @tag capture_log: true
    test "server times out waiting for client connection close", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TimeoutCloseSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Get the sock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "normal")

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}

      # Wait a bit and validate that the server is still very much alive
      Process.sleep(100)
      assert Process.alive?(pid)

      # Now wait for the server to timeout
      Process.sleep(1500)

      # Verify that the server has shut down
      refute Process.alive?(pid)

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end
end
