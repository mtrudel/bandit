defmodule HibernationTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  @hibernating {:current_function, {:erlang, :hibernate, 3}}

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if conn.query_params["websock"],
      do: upgrade_adapter(conn, :websocket, {HibernationTest.Sock, [], []}),
      else: send_resp(conn, 200, "OK")
  end

  defmodule Sock do
    use NoopWebSock
    def handle_in({data, opcode: :text}, state), do: {:push, {:text, data}, state}
  end

  defp connection_pids(context) do
    {:ok, pids} = ThousandIsland.connection_pids(context.server_pid)
    pids
  end

  # A short hibernate_after keeps these tests quick; the point is that nothing in the connection
  # process's loop prevents it from hibernating once idle, and that it carries on afterwards
  describe "idle connection processes" do
    test "hibernate on HTTP/1 between keepalive requests, then serve the next request", context do
      context =
        context
        |> http_server(thousand_island_options: [genserver_options: [hibernate_after: 100]])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)

      Process.sleep(300)
      assert [pid] = connection_pids(context)
      assert Process.info(pid, :current_function) == @hibernating

      SimpleHTTP1Client.send(client, "GET", "/", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)
    end

    test "hibernate on HTTP/2 between requests, then serve the next request", context do
      context =
        context
        |> https_server(thousand_island_options: [genserver_options: [hibernate_after: 100]])
        |> Enum.into(context)

      socket = SimpleH2Client.setup_connection(context)
      {:ok, send_ctx} = SimpleH2Client.send_simple_headers(socket, 1, :get, "/", context.port)
      assert {:ok, 1, false, _headers, recv_ctx} = SimpleH2Client.recv_headers(socket)
      assert {:ok, 1, true, "OK"} = SimpleH2Client.recv_body(socket)

      Process.sleep(300)
      assert [pid] = connection_pids(context)
      assert Process.info(pid, :current_function) == @hibernating

      SimpleH2Client.send_simple_headers(socket, 3, :get, "/", context.port, send_ctx)
      assert {:ok, 3, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket, recv_ctx)
      assert {:ok, 3, true, "OK"} = SimpleH2Client.recv_body(socket)
    end

    test "hibernate on an idle WebSocket, then handle the next frame", context do
      context =
        context
        |> http_server(thousand_island_options: [genserver_options: [hibernate_after: 100]])
        |> Enum.into(context)

      client = SimpleWebSocketClient.tcp_client(context)
      SimpleWebSocketClient.http1_handshake(client, HibernationTest.Sock)

      Process.sleep(300)
      assert [pid] = connection_pids(context)
      assert Process.info(pid, :current_function) == @hibernating

      SimpleWebSocketClient.send_text_frame(client, "still here")
      assert {:ok, "still here"} = SimpleWebSocketClient.recv_text_frame(client)
    end

    test "do not hibernate when hibernate_after is set to :infinity", context do
      context =
        context
        |> http_server(thousand_island_options: [genserver_options: [hibernate_after: :infinity]])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)

      Process.sleep(300)
      assert [pid] = connection_pids(context)
      refute Process.info(pid, :current_function) == @hibernating
    end

    @tag :slow
    test "hibernate after 15 seconds by default", context do
      # The test helpers' 100ms read_timeout would close the connection first
      context =
        context
        |> http_server(thousand_island_options: [read_timeout: 60_000])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)

      Process.sleep(14_000)
      assert [pid] = connection_pids(context)
      refute Process.info(pid, :current_function) == @hibernating

      Process.sleep(4_000)
      assert Process.info(pid, :current_function) == @hibernating
    end
  end
end
