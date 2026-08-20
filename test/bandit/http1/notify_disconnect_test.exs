defmodule HTTP1NotifyDisconnectTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  def call(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["websock"] do
      nil -> super(conn, opts)
      websock -> Plug.Conn.upgrade_adapter(conn, :websocket, {String.to_atom(websock), [], []})
    end
  end

  defp encoded_self, do: self() |> :erlang.term_to_binary() |> Base.encode64()

  def test_pid(conn) do
    conn
    |> get_req_header("x-test-pid")
    |> hd()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  # Wait for a disconnect message, skipping over any other messages (such as Bandit's internal
  # `{:plug_conn, :sent}` message) and putting them back in our mailbox when we're done, just as
  # a well behaved receive loop in a real plug would
  defp watch_for_disconnect(conn, timeout \\ 5_000) do
    pid = test_pid(conn)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_watch_for_disconnect(pid, deadline, [])
    conn
  end

  defp do_watch_for_disconnect(pid, deadline, skipped) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      msg ->
        if Bandit.client_disconnect_message?(msg) do
          requeue(skipped)
          send(pid, :got_disconnect)
        else
          do_watch_for_disconnect(pid, deadline, [msg | skipped])
        end
    after
      remaining ->
        requeue(skipped)
        send(pid, :no_disconnect)
    end
  end

  defp requeue(skipped), do: skipped |> Enum.reverse() |> Enum.each(&send(self(), &1))

  describe "notify_disconnect" do
    test "delivers a disconnect message to the plug process when the client goes away", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/wait_for_disconnect", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert_receive :plug_started, 1000
      Transport.close(client)
      assert_receive :got_disconnect, 1000
    end

    def wait_for_disconnect(conn) do
      send(test_pid(conn), :plug_started)
      conn = watch_for_disconnect(conn)
      send_resp(conn, 204, "")
    end

    test "arms notification once the request body has been completely read", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/read_body_then_wait", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}",
        "content-length: 5"
      ])

      Transport.send(client, "hello")
      assert_receive :body_read, 1000
      Transport.close(client)
      assert_receive :got_disconnect, 1000
    end

    def read_body_then_wait(conn) do
      {:ok, "hello", conn} = read_body(conn)
      send(test_pid(conn), :body_read)
      conn = watch_for_disconnect(conn)
      send_resp(conn, 204, "")
    end

    test "delivers a disconnect message while streaming a chunked response", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/sse_wait", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert_receive :plug_started, 1000
      Transport.close(client)
      assert_receive :got_disconnect, 1000
    end

    def sse_wait(conn) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, "data: hi\n\n")
      send(test_pid(conn), :plug_started)
      watch_for_disconnect(conn)
    end

    test "delivers a disconnect message over TLS", context do
      context =
        context |> https_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = Transport.tls_client(context, ["http/1.1"])

      SimpleHTTP1Client.send(client, "GET", "/wait_for_disconnect", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert_receive :plug_started, 1000
      Transport.close(client)
      assert_receive :got_disconnect, 1000
    end

    test "does not deliver any messages when the option is not set", context do
      context = context |> http_server() |> Enum.into(context)
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/short_watch", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert_receive :plug_started, 1000
      Transport.close(client)
      assert_receive :no_disconnect, 1000
      refute_received :got_disconnect
      refute_received {:unexpected, _}
    end

    def short_watch(conn) do
      send(test_pid(conn), :plug_started)
      conn = watch_for_disconnect(conn, 500)
      send_resp(conn, 204, "")
    end

    test "pipelined requests sent while the socket is being watched are not lost", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/short_wait", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert_receive :plug_started, 1000

      SimpleHTTP1Client.send(client, "GET", "/short_wait", [
        "host: localhost",
        "x-test-pid: #{encoded_self()}"
      ])

      assert {:ok, "200 OK", _headers, "first"} = SimpleHTTP1Client.recv_reply(client)
      assert_receive :plug_started, 1000
      assert {:ok, "200 OK", _headers, "first"} = SimpleHTTP1Client.recv_reply(client)
    end

    def short_wait(conn) do
      send(test_pid(conn), :plug_started)
      Process.sleep(200)
      send_resp(conn, 200, "first")
    end

    test "keepalive requests are served normally when the client stays connected", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      for _ <- 1..3 do
        SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: localhost"])
        assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)
      end
    end

    def hello_world(conn), do: send_resp(conn, 200, "OK")

    defmodule EchoWebSock do
      use NoopWebSock
      def handle_in({data, opcode: :text}, state), do: {:push, {:text, data}, state}
    end

    test "does not interfere with websocket upgrades", context do
      context =
        context |> http_server(http_1_options: [notify_disconnect: true]) |> Enum.into(context)

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, EchoWebSock)
      SimpleWebSocketClient.send_text_frame(client, "hello")
      assert {:ok, "hello"} = SimpleWebSocketClient.recv_text_frame(client)
    end
  end

  describe "client_disconnect_message?/1" do
    test "recognizes socket close and error messages" do
      assert Bandit.client_disconnect_message?({:tcp_closed, :fake_port})
      assert Bandit.client_disconnect_message?({:ssl_closed, :fake_socket})
      assert Bandit.client_disconnect_message?({:tcp_error, :fake_port, :econnreset})
      assert Bandit.client_disconnect_message?({:ssl_error, :fake_socket, :econnreset})
      assert Bandit.client_disconnect_message?({:bandit, {:rst_stream, 8}})
      refute Bandit.client_disconnect_message?({:tcp, :fake_port, "data"})
      refute Bandit.client_disconnect_message?(:other)
    end
  end
end
