defmodule WebSocketProtocolTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    websock = conn.query_params["websock"] |> String.to_atom()
    compress = conn.query_params["compress"]
    Plug.Conn.upgrade_adapter(conn, :websocket, {websock, conn.params, compress: compress})
  end

  # These websocks are used throughout these tests, so declare them top-level
  defmodule EchoWebSock do
    use NoopWebSock
    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    def handle_control({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
  end

  defmodule TerminateWebSock do
    use NoopWebSock
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
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      # Send text frame one byte at a time
      (<<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK")
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(1), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> Transport.send(client, byte) end)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "it should handle cases where a full and partial frame arrive in the same packet",
         context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      # Send one and a half frames
      Transport.send(client, <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK" <> <<8::4, 1::4>>)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}

      # Now send the rest of the second frame
      Transport.send(client, <<1::1, 2::7, 0::32>> <> "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      # Send two text frames at once one byte at a time
      Transport.send(
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
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "mid-sized (16 bit) frames are received properly", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      payload = String.duplicate("0123456789", 1_000)
      SimpleWebSocketClient.send_text_frame(client, payload)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end

    test "large-sized (64 bit) frames are received properly", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      payload = String.duplicate("0123456789", 100_000)
      SimpleWebSocketClient.send_text_frame(client, payload)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end

    @tag capture_log: true
    test "over-sized frames are rejected", context do
      context = http_server(context, websocket_options: [max_frame_size: 2_000_000])
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      payload = String.duplicate("0123456789", 200_001)
      SimpleWebSocketClient.send_text_frame(client, payload)
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1009::16>>}
    end
  end

  describe "frame fragmentation" do
    test "handle_in is called once when fragmented text frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      payload = String.duplicate("0123456789", 1_000)
      SimpleWebSocketClient.send_text_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, expected_payload}
    end

    test "handle_in is called once when fragmented binary frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      payload = String.duplicate("0123456789", 1_000)
      SimpleWebSocketClient.send_binary_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, expected_payload}
    end
  end

  describe "compressed frames" do
    test "correctly decompresses text frames and sends compressed frames back", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      deflated_payload = <<74, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0>>
      SimpleWebSocketClient.send_text_frame(client, deflated_payload, 0xC)

      assert SimpleWebSocketClient.recv_deflated_text_frame(client) == {:ok, deflated_payload}
    end

    test "correctly decompresses binary frames and sends compressed frames back", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      deflated_payload = <<74, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0>>
      SimpleWebSocketClient.send_binary_frame(client, deflated_payload, 0xC)

      assert SimpleWebSocketClient.recv_deflated_binary_frame(client) == {:ok, deflated_payload}
    end

    test "correctly decompresses fragmented text frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      deflated_payload = <<74, 76, 28, 5>>
      deflated_payload_continuation = <<163, 96, 20, 12>>
      deflated_payload_continuation_2 = <<119, 0, 0>>
      SimpleWebSocketClient.send_text_frame(client, deflated_payload, 0x4)
      SimpleWebSocketClient.send_continuation_frame(client, deflated_payload_continuation, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, deflated_payload_continuation_2)

      deflated_payload = <<74, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0>>
      assert SimpleWebSocketClient.recv_deflated_text_frame(client) == {:ok, deflated_payload}
    end

    test "correctly decompresses fragmented binary frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      deflated_payload = <<74, 76, 28, 5>>
      deflated_payload_continuation = <<163, 96, 20, 12>>
      deflated_payload_continuation_2 = <<119, 0, 0>>
      SimpleWebSocketClient.send_binary_frame(client, deflated_payload, 0x4)
      SimpleWebSocketClient.send_continuation_frame(client, deflated_payload_continuation, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, deflated_payload_continuation_2)

      deflated_payload = <<74, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0>>
      assert SimpleWebSocketClient.recv_deflated_binary_frame(client) == {:ok, deflated_payload}
    end

    test "does not compress ping or pong frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      SimpleWebSocketClient.send_ping_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}
    end

    test "does not negotiate compression if not globally configured to", context do
      context = http_server(context, websocket_options: [compress: false])
      client = SimpleWebSocketClient.tcp_client(context)
      assert {:ok, false} = SimpleWebSocketClient.http1_handshake(client, EchoWebSock, [], true)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end
  end

  describe "ping frames" do
    test "send a pong per RFC6455§5.5.2", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}
    end

    test "are processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)
      SimpleWebSocketClient.send_pong_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}

      SimpleWebSocketClient.send_continuation_frame(client, "CD")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "ABCD"}
    end
  end

  describe "server-side connection close" do
    defmodule ServerSideCloseWebSock do
      use NoopWebSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    test "server does a proper shutdown handshake when closing a connection", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, ServerSideCloseWebSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Get the websock to tell bandit to shut down
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
    defmodule ClientSideCloseWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    test "returns a corresponding connection close frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, ClientSideCloseWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, ClientSideCloseWebSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Note that we don't expect this to send back a pid since it won't make it to the WebSock
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
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

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
    test "server sends a 1002 on a compressed frame when deflate not negotiated", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      deflated_payload = <<74, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0>>
      SimpleWebSocketClient.send_text_frame(client, deflated_payload, 0xC)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received unexpected compressed frame (RFC6455§5.2)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on a malformed compressed frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock, [], true)

      deflated_payload = <<1, 2, 3>>
      SimpleWebSocketClient.send_text_frame(client, deflated_payload, 0xC)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Inflation error"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on a non UTF-8 text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8>>, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, <<0x82::8, 0x28::8>>)

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive {:error, "Received non UTF-8 text frame (RFC6455§8.1)"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    test "server does NOT send a 1007 on a non UTF-8 text frame when so configured", context do
      context = http_server(context, websocket_options: [validate_text_frames: false])
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8, 0x82::8, 0x28::8>>)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, <<0xE2::8, 0x82::8, 0x28::8>>}
    end
  end

  describe "timeout conditions" do
    @tag capture_log: true
    test "server sends a 1002 if no frames sent at all", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      # Get the error that terminate saw, to ensure we're closing for the expected reason
      assert_receive :timeout, 1500

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule TimeoutCloseWebSock do
      use NoopWebSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
    end

    @tag capture_log: true
    test "server times out waiting for client connection close", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TimeoutCloseWebSock)

      # Find out the server process pid
      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Get the websock to tell bandit to shut down
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
