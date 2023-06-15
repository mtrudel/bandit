defmodule WebSocketWebSockTest do
  # False due to telemetry tests
  use ExUnit.Case, async: false
  use ServerHelpers
  use Machete

  import ExUnit.CaptureLog

  setup :http_server

  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Bandit.WebSocket.Handshake.valid_upgrade?(conn) do
      true ->
        websock = conn.query_params["websock"] |> String.to_atom()
        Plug.Conn.upgrade_adapter(conn, :websocket, {websock, [], []})

      false ->
        Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  describe "init" do
    defmodule InitOKStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitOKStateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, result} = SimpleWebSocketClient.recv_text_frame(client)
      assert result == inspect(:init)
    end

    defmodule InitPushStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:text, "init"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPushStateWebSock)

      # Ignore the frame it pushes us
      _ = SimpleWebSocketClient.recv_text_frame(client)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(:init)
    end

    defmodule InitReplyStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:reply, :ok, {:text, "init"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitReplyStateWebSock)

      # Ignore the frame it pushes us
      _ = SimpleWebSocketClient.recv_text_frame(client)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(:init)
    end

    defmodule InitTextWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:text, "TEXT"}, :init}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitTextWebSock)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule InitBinaryWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:binary, "BINARY"}, :init}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitBinaryWebSock)

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule InitPingWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:ping, "PING"}, :init}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPingWebSock)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule InitPongWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:pong, "PONG"}, :init}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitPongWebSock)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule InitListWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, [{:pong, "PONG"}, {:text, "TEXT"}], :init}
    end

    test "can return a list of frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitListWebSock)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule InitCloseWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, :init}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitCloseWebSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule InitCloseWithCodeWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, 5555, :init}
    end

    test "can close a connection by returning a stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitCloseWithCodeWebSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule InitAbnormalCloseWithCodeWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :abnormal, 5555, :init}
    end

    @tag capture_log: true
    test "can close a connection by returning an abnormal stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitAbnormalCloseWithCodeWebSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule InitCloseWithCodeAndNilDetailWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, {5555, nil}, :init}
    end

    test "can close a connection by returning a stop tuple with a code and nil detail", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitCloseWithCodeAndNilDetailWebSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule InitCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, {5555, "BOOM"}, :init}
    end

    test "can close a connection by returning a stop tuple with a code and detail", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, InitCloseWithCodeAndDetailWebSock)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
               {:ok, <<5555::16, "BOOM"::binary>>}

      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_in" do
    defmodule HandleInEchoWebSock do
      use NoopWebSock
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "can receive a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInEchoWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    test "can receive a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInEchoWebSock)

      SimpleWebSocketClient.send_binary_frame(client, "OK")

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "OK"}
    end

    defmodule HandleInStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:push, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInStateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"OK", opcode: :text}])
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInStateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_text_frame(client)
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"dump", opcode: :text}])
    end

    defmodule HandleInReplyStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:reply, :ok, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInReplyStateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_text_frame(client)
      SimpleWebSocketClient.send_text_frame(client, "dump")

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect([{"dump", opcode: :text}])
    end

    defmodule HandleInTextWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInTextWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInBinaryWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInBinaryWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleInPingWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInPingWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleInPongWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInPongWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleInListWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, [{:pong, "PONG"}, {:text, "TEXT"}], state}
    end

    test "can return a list of frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInListWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInCloseWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInCloseWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInCloseWithCodeWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, 5555, state}
    end

    test "can close a connection by returning a stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInCloseWithCodeWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInAbnormalCloseWithCodeWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :abnormal, 5555, state}
    end

    @tag capture_log: true
    test "can close a connection by returning an abnormal stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInAbnormalCloseWithCodeWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, {5555, "BOOM"}, state}
    end

    test "can close a connection by returning a stop tuple with a code and detail", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInCloseWithCodeAndDetailWebSock)

      SimpleWebSocketClient.send_text_frame(client, "OK")

      assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
               {:ok, <<5555::16, "BOOM"::binary>>}

      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_control" do
    defmodule HandleControlNoImplWebSock do
      use NoopWebSock
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "callback is optional", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlNoImplWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      assert SimpleWebSocketClient.recv_pong_frame(client)

      # Test that the connection is still alive
      SimpleWebSocketClient.send_text_frame(client, "OK")
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "OK"}
    end

    defmodule HandleControlEchoWebSock do
      use NoopWebSock
      def handle_control({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "can receive a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlEchoWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "OK"}
    end

    test "can receive a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlEchoWebSock)

      SimpleWebSocketClient.send_pong_frame(client, "OK")

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "OK"}
    end

    defmodule HandleControlStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_control({"dump", opcode: :ping} = data, state),
        do: {:push, {:ping, inspect(state)}, [data | state]}

      def handle_control(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlStateWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"OK", opcode: :ping}])
    end

    test "can return a push tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlStateWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      _ = SimpleWebSocketClient.recv_ping_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"dump", opcode: :ping}])
    end

    defmodule HandleControlReplyStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_control({"dump", opcode: :ping} = data, state),
        do: {:reply, :ok, {:ping, inspect(state)}, [data | state]}

      def handle_control(data, state), do: {:ok, [data | state]}
    end

    test "can return a reply tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlReplyStateWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)
      _ = SimpleWebSocketClient.recv_ping_frame(client)
      SimpleWebSocketClient.send_ping_frame(client, "dump")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      {:ok, response} = SimpleWebSocketClient.recv_ping_frame(client)
      assert response == inspect([{"dump", opcode: :ping}])
    end

    defmodule HandleControlTextWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlTextWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleControlBinaryWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlBinaryWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleControlPingWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlPingWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleControlPongWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlPongWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleControlListWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:push, [{:pong, "PONG"}, {:text, "TEXT"}], state}
    end

    test "can return a list of frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlListWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleControlCloseWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlCloseWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleControlCloseWithCodeWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:stop, :normal, 5555, state}
    end

    test "can close a connection by returning a stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlCloseWithCodeWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleControlAbnormalCloseWithCodeWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:stop, :abnormal, 5555, state}
    end

    @tag capture_log: true
    test "can close a connection by returning an abnormal stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlAbnormalCloseWithCodeWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleControlCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def handle_control(_data, state), do: {:stop, :normal, {5555, "BOOM"}, state}
    end

    test "can close a connection by returning a stop tuple with a code and detail", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleControlCloseWithCodeAndDetailWebSock)

      SimpleWebSocketClient.send_ping_frame(client, "OK")
      _ = SimpleWebSocketClient.recv_pong_frame(client)

      assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
               {:ok, <<5555::16, "BOOM"::binary>>}

      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "handle_info" do
    defmodule HandleInfoStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info("dump" = data, state), do: {:push, {:text, inspect(state)}, [data | state]}
      def handle_info(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoStateWebSock)

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
      SimpleWebSocketClient.http1_handshake(client, HandleInfoStateWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

      Process.send(pid, "dump", [])
      _ = SimpleWebSocketClient.recv_text_frame(client)
      Process.send(pid, "dump", [])

      {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
      assert response == inspect(["dump"])
    end

    defmodule HandleInfoTextWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoTextWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInfoBinaryWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoBinaryWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
    end

    defmodule HandleInfoPingWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:ping, "PING"}, state}
    end

    test "can return a ping frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoPingWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
    end

    defmodule HandleInfoPongWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, {:pong, "PONG"}, state}
    end

    test "can return a pong frame", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoPongWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
    end

    defmodule HandleInfoListWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:push, [{:pong, "PONG"}, {:text, "TEXT"}], state}
    end

    test "can return a list of frames", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoListWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
      assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
    end

    defmodule HandleInfoCloseWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInfoCloseWithCodeWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:stop, :normal, 5555, state}
    end

    test "can close a connection by returning a stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInfoAbnormalCloseWithCodeWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:stop, :abnormal, 5555, state}
    end

    @tag capture_log: true
    test "can close a connection by returning an abnormal stop tuple with a code", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoAbnormalCloseWithCodeWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end

    defmodule HandleInfoCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
      def handle_info(_data, state), do: {:stop, :normal, {5555, "BOOM"}, state}
    end

    test "can close a connection by returning a stop tuple with a code and detail", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeAndDetailWebSock)

      SimpleWebSocketClient.send_text_frame(client, "whoami")
      {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
      pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
      Process.send(pid, "OK", [])

      assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
               {:ok, <<5555::16, "BOOM"::binary>>}

      assert SimpleWebSocketClient.connection_closed_for_reading?(client)
    end
  end

  describe "terminate" do
    setup do
      Process.register(self(), __MODULE__)
      :ok
    end

    def send(msg), do: send(__MODULE__, msg)

    defmodule TerminateNoImplWebSock do
      def init(_), do: {:ok, []}
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
    end

    test "callback is optional", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateNoImplWebSock)

      warnings =
        capture_log(fn ->
          # Get the websock to tell bandit to shut down
          SimpleWebSocketClient.send_text_frame(client, "normal")

          # Give Bandit a chance to explode if it's going to
          Process.sleep(100)
        end)

      refute warnings =~ "UndefinedFunctionError"
    end

    defmodule TerminateWebSock do
      use NoopWebSock
      def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
      def handle_in({"boom", opcode: :text}, state), do: {:stop, :boom, state}
      def terminate(reason, _state), do: WebSocketWebSockTest.send(reason)
    end

    test "is called with :normal on a normal connection shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      # Get the websock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "normal")

      assert_receive :normal
    end

    @tag capture_log: true
    test "is called with {:error, reason} on an error connection shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      # Get the websock to tell bandit to shut down
      SimpleWebSocketClient.send_text_frame(client, "boom")

      assert_receive {:error, :boom}
    end

    test "is called with :shutdown on a server shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      # Shut the server down in an orderly manner
      ThousandIsland.stop(context.server_pid)

      assert_receive :shutdown
    end

    test "is called with :remote on a normal remote shutdown", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      SimpleWebSocketClient.send_connection_close_frame(client, 1000)

      assert_receive :remote
    end

    test "is called with {:error, reason} on a protocol error", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      :gen_tcp.close(client)

      assert_receive {:error, :closed}
    end

    @tag capture_log: true
    test "is called with :timeout on a timeout", context do
      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

      assert_receive :timeout, 1500
    end
  end

  describe "telemetry" do
    defmodule TelemetrySock do
      use NoopWebSock
      def handle_in({"close", _}, state), do: {:stop, :normal, state}
      def handle_in({"abnormal_close", _}, state), do: {:stop, :nope, state}
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "it should send `start` events on websocket connection", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :start]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :start],
                %{monotonic_time: integer(), compress: maybe(boolean())},
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should gather send and recv metrics for inclusion in `stop` events", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      SimpleWebSocketClient.send_text_frame(client, "1234")
      SimpleWebSocketClient.send_binary_frame(client, "12345")
      SimpleWebSocketClient.send_ping_frame(client, "123456")
      SimpleWebSocketClient.send_pong_frame(client, "1234567")
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  recv_text_frame_count: 1,
                  recv_text_frame_bytes: 4,
                  recv_binary_frame_count: 1,
                  recv_binary_frame_bytes: 5,
                  recv_ping_frame_count: 1,
                  recv_ping_frame_bytes: 6,
                  recv_pong_frame_count: 1,
                  recv_pong_frame_bytes: 7,
                  recv_connection_close_frame_count: 1,
                  recv_connection_close_frame_bytes: 0,
                  send_text_frame_count: 1,
                  send_text_frame_bytes: 4,
                  send_binary_frame_count: 1,
                  send_binary_frame_bytes: 5,
                  send_pong_frame_count: 1,
                  send_pong_frame_bytes: 6
                },
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should send `stop` events on normal websocket client disconnection", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      SimpleWebSocketClient.send_connection_close_frame(client, 1000)
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  recv_connection_close_frame_count: 1,
                  recv_connection_close_frame_bytes: 0
                },
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should send `stop` events on normal websocket server disconnection", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      SimpleWebSocketClient.send_text_frame(client, "close")
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  recv_text_frame_count: 1,
                  recv_text_frame_bytes: 5
                },
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should send `stop` events on normal server shutdown", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      ThousandIsland.stop(context.server_pid)
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop], %{monotonic_time: integer(), duration: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    @tag capture_log: true
    test "it should send `stop` events on abnormal websocket server disconnection", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      SimpleWebSocketClient.send_text_frame(client, "abnormal_close")
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  recv_text_frame_count: 1,
                  recv_text_frame_bytes: 14
                },
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  error: :nope
                }}
             ]
    end

    test "it should send `stop` events on timeout", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :websocket, :stop]]})

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, TelemetrySock)
      Process.sleep(1100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :websocket, :stop], %{monotonic_time: integer(), duration: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  origin_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  error: :timeout
                }}
             ]
    end
  end
end
