defmodule WebSocketSockTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Bandit.WebSocket.Handshake.valid_upgrade?(conn) do
      true ->
        sock = conn.query_params["sock"] |> String.to_atom()
        Plug.Conn.upgrade_adapter(conn, :websocket, {sock, [], []})

      false ->
        Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  describe "init" do
    defmodule InitOKStateSock do
      use NoopSock
      def init(_opts), do: {:ok, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitOKStateSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)
      assert result == inspect(:init)
    end

    defmodule InitPushStateSock do
      use NoopSock
      def init(_opts), do: {:push, {:text, "init"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPushStateSock)

      # Ignore the frame it pushes us
      _ = SimpleWebSocketClient.recv_text_frame(client)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(:init)
    end

    defmodule InitReplyStateSock do
      use NoopSock
      def init(_opts), do: {:reply, :ok, {:text, "init"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitReplyStateSock)

      # Ignore the frame it pushes us
      _ = SimpleWebSocketClient.recv_text_frame(client)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(:init)
    end

    defmodule InitTextSock do
      use NoopSock
      def init(_opts), do: {:push, {:text, "TEXT"}, :init}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitTextSock)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule InitBinarySock do
      use NoopSock
      def init(_opts), do: {:push, {:binary, "BINARY"}, :init}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitBinarySock)

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule InitPingSock do
      use NoopSock
      def init(_opts), do: {:push, {:ping, "PING"}, :init}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPingSock)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule InitPongSock do
      use NoopSock
      def init(_opts), do: {:push, {:pong, "PONG"}, :init}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPongSock)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule InitCloseSock do
      use NoopSock
      def init(_opts), do: {:stop, :normal, :init}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitCloseSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_in" do
    defmodule HandleInEchoSock do
      use NoopSock
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "can receive a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInEchoSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "can receive a bianry frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInEchoSock)

      SimpleWebSocketClient.send_binary_frame(client, "OK")

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "OK"}
    end

    defmodule HandleInStateSock do
      use NoopSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:push, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInStateSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"OK", opcode: :text}])
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInStateSock)

      SimpleWebSocketClient.send_text_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_text_frame(client)
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"dump", opcode: :text}])
    end

    defmodule HandleInReplyStateSock do
      use NoopSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:reply, :ok, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInReplyStateSock)

      SimpleWebSocketClient.send_text_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_text_frame(client)
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"dump", opcode: :text}])
    end

    defmodule HandleInTextSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInTextSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInBinarySock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInBinarySock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleInPingSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInPingSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleInPongSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInPongSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleInCloseSock do
      use NoopSock
      def handle_in(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInCloseSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_control" do
    defmodule HandleControlNoImplSock do
      use NoopSock
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "callback is optional", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlNoImplSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      assert SimpleWebSocketClient.recv_pong_frame(client)

      # Test that the connection is still alive
      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    defmodule HandleControlEchoSock do
      use NoopSock
      def handle_control({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "can receive a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlEchoSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}
    end

    test "can receive a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlEchoSock)

      SimpleWebSocketClient.send_pong_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
    end

    defmodule HandleControlStateSock do
      use NoopSock
      def init(_opts), do: {:ok, []}

      def handle_control({"dump", opcode: :ping} = data, state),
        do: {:push, {:ping, inspect(state)}, [data | state]}

      def handle_control(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlStateSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"OK", opcode: :ping}])
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlStateSock)

      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      _ = SimpleWebSocketClient.recv_ping_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"dump", opcode: :ping}])
    end

    defmodule HandleControlReplyStateSock do
      use NoopSock
      def init(_opts), do: {:ok, []}

      def handle_control({"dump", opcode: :ping} = data, state),
        do: {:reply, :ok, {:ping, inspect(state)}, [data | state]}

      def handle_control(data, state), do: {:ok, [data | state]}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlReplyStateSock)

      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      _ = SimpleWebSocketClient.recv_ping_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"dump", opcode: :ping}])
    end

    defmodule HandleControlTextSock do
      use NoopSock
      def handle_control(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlTextSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleControlBinarySock do
      use NoopSock
      def handle_control(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlBinarySock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleControlPingSock do
      use NoopSock
      def handle_control(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlPingSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleControlPongSock do
      use NoopSock
      def handle_control(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlPongSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleControlCloseSock do
      use NoopSock
      def handle_control(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlCloseSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_info" do
    defmodule HandleInfoStateSock do
      use NoopSock
      def init(_opts), do: {:ok, []}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info("dump" = data, state), do: {:push, {:text, inspect(state)}, [data | state]}
      def handle_info(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoStateSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      Process.send(pid, "OK", [])
      Process.send(pid, "dump", [])

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(["OK"])
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoStateSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      Process.send(pid, "dump", [])
      _ = SimpleWebSocketClient.recv_text_frame(client)
      Process.send(pid, "dump", [])

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(["dump"])
    end

    defmodule HandleInfoTextSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoTextSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInfoBinarySock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoBinarySock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleInfoPingSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoPingSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleInfoPongSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoPongSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleInfoCloseSock do
      use NoopSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "terminate" do
    setup do
      Process.register(self(), __MODULE__)
      :ok
    end

    def send(msg), do: send(__MODULE__, msg)

    defmodule TerminateSock do
      use NoopSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in({"boom", opcode: :text}, state), do: {:stop, :boom, state}
      def terminate(reason, _state), do: WebSocketSockTest.send(reason)
    end

    test "is called with :normal on a normal connection shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      # Get the sock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "normal")

      assert_receive :normal
    end

    @tag capture_log: true
    test "is called with {:error, reason} on an error connection shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      # Get the sock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "boom")

      assert_receive {:error, :boom}
    end

    test "is called with :shutdown on a server shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      # Shut the server down in an orderly manner
      ThousandIsland.stop(context.server_pid)

      assert_receive :shutdown
    end

    test "is called with :remote on a normal remote shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      assert_receive :remote
    end

    test "is called with {:error, reason} on a protocol error", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      :gen_tcp.close(client)

      assert_receive {:error, :closed}
    end

    @tag capture_log: true
    test "is called with :timeout on a timeout", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateSock)

      assert_receive :timeout, 1500
    end
  end
end
