defmodule WebSocketSockTest do
  use WebSocketServerHelpers

  setup :http1_websocket_server

  describe "option passing" do
    test "options are collected from static config, init, negotiate, and handle_* calls",
         context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_connection: :add_opts,
        handle_text_frame: :add_and_echo_opts
      )

      SimpleWebSocketClient.send_text_frame(client, "OK 1")

      _ = SimpleWebSocketClient.recv_text_frame(client)

      SimpleWebSocketClient.send_text_frame(client, "OK 2")

      expected =
        inspect(%{
          negotiate: :noop_negotiate,
          handle_connection: :add_opts,
          handle_text_frame: :add_and_echo_opts,
          handle_binary_frame: :noop_handle_binary_frame,
          handle_ping_frame: :noop_handle_ping_frame,
          handle_pong_frame: :noop_handle_pong_frame,
          handle_close: :noop_handle_close,
          handle_error: :noop_handle_error,
          handle_timeout: :noop_handle_timeout,
          handle_info: :noop_handle_info,
          startup_opts: :ok,
          init_opts: :ok,
          handle_connection_opts: :ok,
          handle_text_frame_opts: ["OK 2", "OK 1"]
        })

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, expected}
    end

    def add_opts(_socket, opts) do
      {:continue, Map.put(opts, :handle_connection_opts, :ok)}
    end

    def add_and_echo_opts(data, socket, opts) do
      opts = Map.update(opts, :handle_text_frame_opts, [data], &[data | &1])
      Sock.Socket.send_text_frame(socket, inspect(opts))
      {:continue, opts}
    end
  end

  describe "negotiate" do
    test "can accept a connection to begin its life as a websocket", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, negotiate: :accept, handle_connection: :ok)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    def accept(conn, opts) do
      {:accept, conn, opts, []}
    end

    def ok(socket, opts) do
      Sock.Socket.send_text_frame(socket, "OK")
      {:continue, opts}
    end

    @tag capture_log: true
    test "can specify a timeout option", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        negotiate: :short_timeout,
        handle_timeout: :send_text_on_timeout
      )

      # Send a frame to ensure that whatever timeout we set is persistent
      SimpleWebSocketClient.send_text_frame(client, "OK")

      # Wait long enough for things to timeout
      Process.sleep(100)

      # Make sure that sock.handle_timeout is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TIMEOUT"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def short_timeout(conn, opts) do
      {:accept, conn, opts, timeout: 50}
    end

    test "can refuse a connection to send it back as an HTTP response", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /?#{URI.encode_query(negotiate: :refuse)} HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response =~ ~r"""
             HTTP/1.1 499 Unknown Status Code\r
             date: [a-zA-Z]{3}, \d{2} [a-zA-Z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT\r
             content-length: 10\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             Not today
             """
    end

    def refuse(conn, opts) do
      conn = Plug.Conn.resp(conn, 499, "Not today\n")
      {:refuse, conn, opts}
    end
  end

  describe "handle_connection" do
    test "can interact with the socket at connection time", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_connection: :ok)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "can close a connection by returning a close tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_connection: :close)
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def close(_socket, opts) do
      {:close, opts}
    end
  end

  describe "frame splitting / merging" do
    test "it should handle cases where the frames arrives in small chunks", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

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

      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

      # Send one and a half frames
      :gen_tcp.send(client, <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK" <> <<8::4, 1::4>>)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}

      # Now send the rest of the second frame
      :gen_tcp.send(client, <<1::1, 2::7, 0::32>> <> "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

      # Send two text frames at once one byte at a time
      :gen_tcp.send(
        client,
        <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK" <> <<8::4, 1::4, 1::1, 2::7, 0::32>> <> "OK"
      )

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end
  end

  describe "handle_text_frame" do
    test "is called when small (7 bit) text frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)
      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "is called when mid-sized (16 bit) text frames are sent", context do
      payload = String.duplicate("a", 1_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

      SimpleWebSocketClient.send_text_frame(client, payload)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end

    test "is called when large-sized (64 bit) text frames are sent", context do
      payload = String.duplicate("a", 100_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

      SimpleWebSocketClient.send_text_frame(client, payload)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, payload}
    end

    test "is called when fragmented text frames are sent", context do
      payload = String.duplicate("a", 1_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :echo_text_frame)

      SimpleWebSocketClient.send_text_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, expected_payload}
    end

    def echo_text_frame(data, socket, opts) do
      Sock.Socket.send_text_frame(socket, data)
      {:continue, opts}
    end

    test "can close a connection by returning a close tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_text_frame: :close_text_frame)
      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def close_text_frame(_data, _socket, opts) do
      {:close, opts}
    end
  end

  describe "handle_binary_frame" do
    test "is called when small (7 bit) binary frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_binary_frame: :echo_binary_frame)
      SimpleWebSocketClient.send_binary_frame(client, "OK")
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "OK"}
    end

    test "is called when mid-sized (16 bit) binary frames are sent", context do
      payload = String.duplicate("a", 1_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_binary_frame: :echo_binary_frame)

      SimpleWebSocketClient.send_binary_frame(client, payload)
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, payload}
    end

    test "is called when large-sized (64 bit) binary frames are sent", context do
      payload = String.duplicate("a", 100_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_binary_frame: :echo_binary_frame)

      SimpleWebSocketClient.send_binary_frame(client, payload)
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, payload}
    end

    test "is called when fragmented binary frames are sent", context do
      payload = String.duplicate("a", 1_000)
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_binary_frame: :echo_binary_frame)

      SimpleWebSocketClient.send_binary_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, payload)

      expected_payload = String.duplicate(payload, 3)
      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, expected_payload}
    end

    def echo_binary_frame(data, socket, opts) do
      Sock.Socket.send_binary_frame(socket, data)
      {:continue, opts}
    end

    test "can close a connection by returning a close tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_binary_frame: :close_binary_frame)
      SimpleWebSocketClient.send_binary_frame(client, "OK")
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def close_binary_frame(_data, _socket, opts) do
      {:close, opts}
    end
  end

  describe "handle_ping_frame" do
    test "sends a pong per RFC6455§5.5.2", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client)
      SimpleWebSocketClient.send_ping_frame(client, "OK")
      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
    end

    test "is called when ping frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_ping_frame: :echo_ping_frame)
      SimpleWebSocketClient.send_ping_frame(client, "OK")
      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "is processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :echo_text_frame,
        handle_ping_frame: :echo_ping_frame
      )

      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)
      SimpleWebSocketClient.send_ping_frame(client, "OK")
      SimpleWebSocketClient.send_continuation_frame(client, "CD")
      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "ABCD"}
    end

    def echo_ping_frame(data, socket, opts) do
      Sock.Socket.send_text_frame(socket, data)
      {:continue, opts}
    end
  end

  describe "handle_pong_frame" do
    test "is called when pong frames are sent", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, handle_pong_frame: :echo_pong_frame)
      SimpleWebSocketClient.send_pong_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "is processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :echo_text_frame,
        handle_pong_frame: :echo_pong_frame
      )

      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)
      SimpleWebSocketClient.send_pong_frame(client, "OK")
      SimpleWebSocketClient.send_continuation_frame(client, "CD")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "ABCD"}
    end

    def echo_pong_frame(data, socket, opts) do
      Sock.Socket.send_text_frame(socket, data)
      {:continue, opts}
    end
  end

  describe "handle_info" do
    test "is called when messages are sent to the process", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :send_self_message,
        handle_info: :echo_message
      )

      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    def send_self_message(data, _socket, opts) do
      Process.send(self(), data, [])
      {:continue, opts}
    end

    def echo_message(msg, socket, opts) do
      Sock.Socket.send_text_frame(socket, msg)
      {:continue, opts}
    end
  end

  describe "server-side connection close" do
    test "server shuts down connection with a 1000 on a close tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame_and_close,
        handle_close: :send_text_on_close
      )

      # Get the sock to tell bandit to shut down. It will send us its pid first
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:local, 1000}"}

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

    def pid_text_frame_and_close(_data, socket, opts) do
      Sock.Socket.send_text_frame(socket, :erlang.pid_to_list(self()))
      {:close, opts}
    end

    def send_text_on_close(reason, socket, _opts) do
      Sock.Socket.send_text_frame(socket, inspect(reason))
      :ok
    end

    test "server shuts down connection with a 1000 on close tuple from handle_info", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame_and_send_self_message,
        handle_info: :echo_message_and_close,
        handle_close: :send_text_on_close
      )

      # Get the sock to tell bandit to shut down. It will send us its pid first
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Make sure that sock.handle_info is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:local, 1000}"}

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

    def pid_text_frame_and_send_self_message(_data, socket, opts) do
      Sock.Socket.send_text_frame(socket, :erlang.pid_to_list(self()))
      Process.send(self(), "OK", [])
      {:continue, opts}
    end

    def echo_message_and_close(msg, socket, opts) do
      Sock.Socket.send_text_frame(socket, msg)
      {:close, opts}
    end

    test "server shuts down connection with a 1001 on clean shut down", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_close: :send_text_on_close)

      # Shut the server down in an orderly manner
      ThousandIsland.stop(context.server_pid)

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:local, 1001}"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1001::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "client-side connection close" do
    test "returns a corresponding connection close frame and calls the sock callback", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame,
        handle_close: :send_text_on_close
      )

      # Get the server pid and ensure it's alive
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      assert Process.alive?(pid)

      # Close the connection from the client
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:remote, 1000}"}

      # Now ensure that we see the server's half of the shutdown handshake
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "is processed when interleaved with continuation frames", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame,
        handle_close: :send_text_on_close
      )

      # Get the server pid and ensure it's alive
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      assert Process.alive?(pid)

      # Note that we don't expect this to send back a pid since it won't make it to the Sock
      SimpleWebSocketClient.send_text_frame(client, "AB", 0x0)

      # Close the connection from the client
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:remote, 1000}"}

      # Now ensure that we see the server's half of the shutdown handshake
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    def pid_text_frame(_data, socket, opts) do
      Sock.Socket.send_text_frame(socket, :erlang.pid_to_list(self()))
      {:continue, opts}
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "calls sock callback and closes websocket on error tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :return_error,
        handle_error: :send_text_on_error
      )

      # Get the sock to tell bandit to return an error. It will send us its pid first
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "nope"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1011::16>>}

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "calls sock callback and closes websocket on error tuple from handle_info", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :send_self_message,
        handle_info: :return_error,
        handle_error: :send_text_on_error
      )

      # Get the sock to tell bandit to return an error. It will send us its pid first
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "nope"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1011::16>>}

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def return_error(_data, socket, opts) do
      Sock.Socket.send_text_frame(socket, :erlang.pid_to_list(self()))
      {:error, "nope", opts}
    end

    def send_text_on_error(reason, socket, _opts) do
      Sock.Socket.send_text_frame(socket, reason)
      :ok
    end

    test "an abnormal socket close calls sock callback", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame_and_send_message_on_close,
        handle_error: :send_message_on_error
      )

      # Get the server pid and ensure it's alive
      my_pid = self() |> :erlang.pid_to_list() |> to_string()
      SimpleWebSocketClient.send_text_frame(client, my_pid)
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      assert Process.alive?(pid)

      # Close the client connection abnormally
      :gen_tcp.close(client)

      # Make sure that sock.handle_error is called
      assert_receive "Reason closed"

      # Now ensure that we do not see a connection close frame from the server
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)

      # Wait a bit and validate that the server is closed
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    def pid_text_frame_and_send_message_on_close(data, socket, opts) do
      their_pid = data |> String.to_charlist() |> :erlang.list_to_pid()
      Sock.Socket.send_text_frame(socket, :erlang.pid_to_list(self()))
      {:continue, Map.put(opts, :their_pid, their_pid)}
    end

    def send_message_on_error(reason, _socket, opts) do
      Process.send(opts[:their_pid], "Reason #{reason}", [])
      :ok
    end

    @tag capture_log: true
    test "server sends a 1002 on an unexpected continuation frame", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_error: :send_text_on_error)

      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_continuation_frame(client, <<1, 2, 3>>)

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) ==
               {:ok, "Received unexpected continuation frame (RFC6455§5.4)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 on a text frame during continuation", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_error: :send_text_on_error)

      SimpleWebSocketClient.send_text_frame(client, <<1, 2, 3>>, 0x0)
      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_text_frame(client, <<1, 2, 3>>)

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) ==
               {:ok, "Received unexpected text frame (RFC6455§5.4)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 on a binary frame during continuation", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_error: :send_text_on_error)

      SimpleWebSocketClient.send_binary_frame(client, <<1, 2, 3>>, 0x0)
      # This is not allowed by RFC6455§5.4
      SimpleWebSocketClient.send_binary_frame(client, <<1, 2, 3>>)

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) ==
               {:ok, "Received unexpected binary frame (RFC6455§5.4)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on a non UTF-8 text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_error: :send_text_on_error)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8, 0x82::8, 0x28::8>>)

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) ==
               {:ok, "Received non UTF-8 text frame (RFC6455§8.1)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1007 on fragmented non UTF-8 text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_error: :send_text_on_error)

      SimpleWebSocketClient.send_text_frame(client, <<0xE2::8>>, 0x0)
      SimpleWebSocketClient.send_continuation_frame(client, <<0x82::8, 0x28::8>>)

      # Make sure that sock.handle_error is called
      assert SimpleWebSocketClient.recv_text_frame(client) ==
               {:ok, "Received non UTF-8 text frame (RFC6455§8.1)"}

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1007::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "timeout conditions" do
    @tag capture_log: true
    test "server sends a 1002 and calls the sock callback if no frames sent", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_timeout: :send_text_on_timeout)

      # Wait long enough for things to timeout
      Process.sleep(1000)

      # Make sure that sock.handle_timeout is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TIMEOUT"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    @tag capture_log: true
    test "server sends a 1002 and calls the sock callback on timeout between frames",
         context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client, handle_timeout: :send_text_on_timeout)
      SimpleWebSocketClient.send_text_frame(client, "OK")

      # Wait long enough for things to timeout
      Process.sleep(1000)

      # Make sure that sock.handle_timeout is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TIMEOUT"}

      # Validate that the server has started the shutdown handshake from RFC6455§7.1.2
      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1002::16>>}

      # Verify that the server didn't send any extraneous frames
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    def send_text_on_timeout(socket, _opts) do
      Sock.Socket.send_text_frame(socket, "TIMEOUT")
      :ok
    end

    @tag capture_log: true
    test "server times out waiting for client connection close", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleWebSocketClient.http1_handshake(client,
        handle_text_frame: :pid_text_frame_and_close,
        handle_close: :send_text_on_close
      )

      # Get the sock to tell bandit to shut down. It will send us its pid first
      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      # Make sure that sock.handle_close is called
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "{:local, 1000}"}

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
