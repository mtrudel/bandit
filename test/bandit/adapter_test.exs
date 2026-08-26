defmodule Bandit.AdapterTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  require Logger

  # Bandit.Adapter implements Plug.Conn.Adapter once, shared verbatim by both the HTTP/1 and
  # HTTP/2 stacks - its behaviour doesn't vary by protocol, so it's tested here against a single
  # (HTTP/1) server rather than duplicated per protocol.

  setup :http_server
  setup :req_http1_client

  describe "calling process validation" do
    test "raises if read_body is called from a process other than the stream owner", context do
      response = Req.post!(context.req, url: "/other_process_body_read", body: "OK")

      assert response.status == 200
    end

    def other_process_body_read(conn) do
      {:ok, "OK", conn} = read_body(conn)

      error =
        Task.async(fn ->
          try do
            read_body(conn)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if send_resp is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_resp")

      assert response.status == 200
    end

    def other_process_send_resp(conn) do
      error =
        Task.async(fn ->
          try do
            send_resp(conn, 200, "NOT OK")
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if send_chunked is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_chunked")

      assert response.status == 200
    end

    def other_process_send_chunked(conn) do
      error =
        Task.async(fn ->
          try do
            send_chunked(conn, 200)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if chunk is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_chunk")

      assert response.status == 200
    end

    def other_process_chunk(conn) do
      conn = send_chunked(conn, 200)

      error =
        Task.async(fn ->
          try do
            chunk(conn, "NOT OK")
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      {:ok, conn} = chunk(conn, "OK")
      conn
    end

    @tag :capture_log
    test "raises if send_file is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_file")

      assert response.status == 200
    end

    def other_process_send_file(conn) do
      error =
        Task.async(fn ->
          try do
            send_file(conn, 200, Path.join([__DIR__, "../support/sendfile"]), 0, :all)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if inform is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_inform")

      assert response.status == 200
    end

    def other_process_inform(conn) do
      error =
        Task.async(fn ->
          try do
            inform(conn, 100, [])
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end
  end

  # https://github.com/mtrudel/bandit/issues/649 - using a conn from before a mutating
  # Plug.Conn.Adapter call (read_body, send_resp, send_chunked, chunk, send_file, inform,
  # upgrade_adapter) instead of the one it returned used to silently corrupt state - most
  # dangerously, the next request on the connection (ensure_completed would drain the wrong
  # number of bytes off the wire, having been handed stale bookkeeping about how much of the
  # body was actually already read). Every callback that returns a new conn should instead raise
  # immediately, on this request, the moment it's handed a conn that isn't the most recently
  # returned one.
  describe "stale conn validation" do
    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for read_body", context do
      assert_stale_conn_raises(context, "/stale_before_read_body")
    end

    def stale_before_read_body(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      {:ok, _body, _conn} = read_body(conn)
      send_resp(conn, 200, "unreachable")
    end

    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for send_resp", context do
      assert_stale_conn_raises(context, "/stale_before_send_resp")
    end

    def stale_before_send_resp(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      send_resp(conn, 200, "unreachable")
    end

    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for send_chunked", context do
      assert_stale_conn_raises(context, "/stale_before_send_chunked")
    end

    def stale_before_send_chunked(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      send_chunked(conn, 200)
    end

    @tag :capture_log
    test "raises if a stale conn from before a chunk is reused for a later chunk", context do
      # Plug.Conn.chunk/2 requires the conn to already be in :chunked state, so unlike the other
      # stale-conn cases here, staleness has to be established between two live chunk/2 calls
      # rather than via an unrelated read_body/2 call. By the time the second (stale) call
      # raises, headers have already gone out, so Bandit can't retroactively send a fresh error
      # status - it just tears the connection down instead, which the client observes as a
      # malformed/incomplete response at a point that's a timing race, and so not worth pinning
      # down exactly. Only the one deterministic, server-side signal is asserted on here.
      _ = Req.get(context.req, url: "/stale_before_chunk")

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "Stale conn passed to a Plug.Conn function"
    end

    def stale_before_chunk(conn) do
      conn = send_chunked(conn, 200)
      {:ok, _fresher_conn} = chunk(conn, "first")
      {:ok, _conn} = chunk(conn, "second")
      conn
    end

    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for send_file", context do
      assert_stale_conn_raises(context, "/stale_before_send_file")
    end

    def stale_before_send_file(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      send_file(conn, 200, Path.join([__DIR__, "../support/sendfile"]), 0, :all)
    end

    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for inform", context do
      assert_stale_conn_raises(context, "/stale_before_inform")
    end

    def stale_before_inform(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      conn |> inform(100, []) |> send_resp(200, "unreachable")
    end

    @tag :capture_log
    test "raises if a stale conn from before read_body is reused for upgrade", context do
      assert_stale_conn_raises(context, "/stale_before_upgrade")
    end

    defmodule MyNoopWebSock do
      use NoopWebSock
    end

    def stale_before_upgrade(conn) do
      {:ok, _body, _fresh_conn} = read_body(conn)
      upgrade_adapter(conn, :websocket, {MyNoopWebSock, [], []})
    end

    defp assert_stale_conn_raises(context, path) do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", path, ["host: banana", "content-length: 2"])
      Transport.send(client, "OK")

      assert {:ok, "500 Internal Server Error", _headers, _} =
               SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "Stale conn passed to a Plug.Conn function"

      # The connection is closed rather than kept alive, so there's no "next request" for the
      # stale conn's bad bookkeeping to corrupt
      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def hello_world(conn) do
      send_resp(conn, 200, "OK")
    end
  end

  # A conn is only stale - and should only trip the check above - once some other, newer copy
  # of it has actually advanced the connection. Some Plug.Conn.Adapter callbacks have paths that
  # report failure without returning a new conn at all (Plug's documented behaviour in that case
  # is for the caller to keep using its already-current conn), so those paths must not advance
  # the connection either, or they'd make the caller's still-current conn look stale.
  describe "usage counter is not advanced when no new conn is produced" do
    test "inform does not advance the counter when declined for an HTTP/1.0 client", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/decline_then_send_resp", ["host: banana"], "1.0")

      assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)
    end

    def decline_then_send_resp(conn) do
      # inform/3 reports {:error, :not_supported} for HTTP/1.0 clients without returning a new
      # conn - Plug.Conn.inform/3 returns `conn` unchanged in that case, so this is exactly the
      # same (still-current) conn send_resp is then called with
      conn = inform(conn, 100, [{"x-from", "inform"}])
      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "upgrade does not advance the counter when unsupported", context do
      context =
        context
        |> http_server(websocket_options: [enabled: false])
        |> Enum.into(context)

      response = Req.get!(context.req, url: "/upgrade_then_rescue", base_url: context.base)

      assert response.status == 200
      assert response.body == "OK"
    end

    defmodule MyOtherNoopWebSock do
      use NoopWebSock
    end

    def upgrade_then_rescue(conn) do
      # In actual use, it's the caller's responsibility to ensure the upgrade is valid before
      # calling upgrade_adapter. On failure, Plug.Conn.upgrade_adapter/3 raises ArgumentError
      # without returning a new conn, so the documented recovery is to keep using this (still
      # current) conn - exactly what the rescue clause below does.
      upgrade_adapter(conn, :websocket, {MyOtherNoopWebSock, [], []})
    rescue
      ArgumentError -> send_resp(conn, 200, "OK")
    end

    test "chunk does not advance the counter when the transport raises", context do
      # Force a genuine Bandit.TransportError deterministically (rather than racing a client
      # disconnect) by having the plug close its own underlying socket mid-response, then
      # attempting to write to it twice. `Req.get/2` (not `Req.get!/2`) is used since the
      # connection closing mid-response is expected to surface as a client-side error too - the
      # only thing this test cares about is what the server logs
      _ = Req.get(context.req, url: "/close_socket_then_chunk_twice")

      assert_receive {:log, %{level: :info, msg: {:string, msg}}}, 500
      assert msg == "both post-close chunk/2 calls failed without raising a stale-conn error"
    end

    def close_socket_then_chunk_twice(conn) do
      conn = send_chunked(conn, 200)
      {Bandit.Adapter, adapter} = conn.adapter
      ThousandIsland.Socket.close(adapter.transport.socket)

      # chunk/2 is unique among Plug.Conn.Adapter's sending callbacks in that it reports
      # transport errors as an {:error, reason} return value rather than raising - Plug's
      # Plug.Conn.chunk/2 does not return a new conn in that case, so the caller keeps using its
      # already-current (here, still broken) conn. If chunk/2 had incorrectly advanced the usage
      # counter on the first (failed) call, the second call would raise "Stale conn passed to a
      # Plug.Conn function" instead of returning the same {:error, _} shape
      {:error, _} = chunk(conn, "first")
      {:error, _} = chunk(conn, "second")

      Logger.info("both post-close chunk/2 calls failed without raising a stale-conn error",
        plug: {__MODULE__, []}
      )

      conn
    end
  end
end
