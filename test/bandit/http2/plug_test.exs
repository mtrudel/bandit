defmodule HTTP2PlugTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  setup :https_server
  setup :req_h2_client

  describe "plug definitions" do
    test "runs module plugs", context do
      response = Req.get!(context.req, url: "/hello_world")
      assert response.status == 200
      assert response.body == "OK module"
    end

    def hello_world(conn) do
      send_resp(conn, 200, "OK module")
    end

    test "runs function plugs", context do
      context =
        context
        |> https_server(plug: fn conn, _ -> send_resp(conn, 200, "OK function") end)
        |> Enum.into(context)

      response = Req.get!(context.req, url: "/", base_url: context.base)
      assert response.status == 200
      assert response.body == "OK function"
    end
  end

  describe "error response & logging" do
    @tag :capture_log
    test "it should return 500 and log when unknown exceptions are raised", context do
      {:ok, response} = Req.get(context.req, url: "/unknown_crasher")
      assert response.status == 500

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (RuntimeError) boom"
    end

    def unknown_crasher(_conn) do
      raise "boom"
    end

    test "it should return the code and not log when known exceptions are raised", context do
      {:ok, response} = Req.get(context.req, url: "/known_crasher")
      assert response.status == 418

      refute_receive {:log, %{level: :error}}
    end

    @tag :capture_log
    test "it should log known exceptions if so configured", context do
      context =
        context
        |> https_server(http_options: [log_exceptions_with_status_codes: 100..599])
        |> Enum.into(context)

      {:ok, response} = Req.get(context.req, url: "/known_crasher", base_url: context.base)
      assert response.status == 418

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (SafeError) boom"
    end

    def known_crasher(_conn) do
      raise SafeError, "boom"
    end
  end

  test "reading request headers", context do
    response =
      Req.head!(context.req, url: "/header_read_test", headers: [{"x-request-header", "Request"}])

    assert response.status == 200
  end

  def header_read_test(conn) do
    assert get_req_header(conn, "x-request-header") == ["Request"]

    conn |> send_resp(200, <<>>)
  end

  test "request headers do not include pseudo headers", context do
    response = Req.head!(context.req, url: "/no_pseudo_header")

    assert response.status == 200
  end

  def no_pseudo_header(conn) do
    assert get_req_header(conn, ":scheme") == []

    conn |> send_resp(200, <<>>)
  end

  test "reading request body when there is no body sent", context do
    response = Req.head!(context.req, url: "/empty_body_read")

    assert response.status == 200
  end

  def empty_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == ""
    conn |> send_resp(200, body)
  end

  test "reading request body when there is a simple body sent", context do
    response = Req.post!(context.req, url: "/simple_body_read", body: "OK")

    assert response.status == 200
  end

  def simple_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == "OK"
    conn |> send_resp(200, body)
  end

  test "reading request body multiple times works as expected", context do
    response = Req.post!(context.req, url: "/multiple_body_read", body: "OK")

    assert response.status == 200
  end

  def multiple_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == "OK"
    {:ok, "", conn} = read_body(conn)
    conn |> send_resp(200, body)
  end

  @tag :capture_log
  test "reading request body from another process works as expected", context do
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

  test "reading request body respects length option", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :post, "/length_body_read", context.port)
    SimpleH2Client.send_body(socket, 1, false, "A")
    SimpleH2Client.send_body(socket, 1, false, "B")
    SimpleH2Client.send_body(socket, 1, false, "C")
    SimpleH2Client.send_body(socket, 1, false, "D")
    SimpleH2Client.send_body(socket, 1, true, "E")

    {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
    {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

    assert SimpleH2Client.successful_response?(socket, 1, false)
    assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
  end

  def length_body_read(conn) do
    {:more, body, conn} = read_body(conn, length: 2)
    assert body == "ABC"
    {:ok, body, conn} = read_body(conn)
    assert body == "DE"
    conn |> send_resp(200, <<>>)
  end

  test "reading request body respects timeout option", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :post, "/timeout_body_read", context.port)
    SimpleH2Client.send_body(socket, 1, false, "A")
    {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
    {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
    Process.sleep(50)
    SimpleH2Client.send_body(socket, 1, true, "BC")

    assert SimpleH2Client.successful_response?(socket, 1, false)
    assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}

    Process.sleep(100)
  end

  def timeout_body_read(conn) do
    {:more, body, conn} = read_body(conn, read_timeout: 10)
    assert body == "A"
    {:ok, body, conn} = read_body(conn)
    assert body == "BC"
    conn |> send_resp(200, <<>>)
  end

  test "stream is closed without error if plug does not read body", context do
    socket = SimpleH2Client.setup_connection(context)

    headers = [
      {":method", "post"},
      {":path", "/no_body_read"},
      {":scheme", "https"},
      {":authority", "localhost:#{context.port}"},
      {"content-length", "3"}
    ]

    SimpleH2Client.send_headers(socket, 1, false, headers)
    SimpleH2Client.send_body(socket, 1, true, "ABC")

    # Ordering of window update frames can be racy due to h2's internal message passing
    assert [
             SimpleH2Client.recv_frame(socket),
             SimpleH2Client.recv_frame(socket),
             SimpleH2Client.recv_frame(socket)
           ]
           ~> in_any_order([
             {:ok, :window_update, term(), 0, term()},
             {:ok, :headers, term(), 1, term()},
             {:ok, :data, term(), 1, term()}
           ])
  end

  def no_body_read(conn) do
    conn |> send_resp(200, "")
  end

  test "writing response headers", context do
    response = Req.head!(context.req, url: "/header_write_test")

    assert response.status == 200
    assert map_size(response.headers) == 4

    assert %{
             "date" => [date],
             "vary" => ["accept-encoding"],
             "cache-control" => ["max-age=0, private, must-revalidate"],
             "X-Response-Header" => ["Response"]
           } = response.headers

    assert DateHelpers.valid_date_header?(date)
  end

  def header_write_test(conn) do
    conn
    |> put_resp_header("X-Response-Header", "Response")
    |> send_resp(200, <<>>)
  end

  test "writing user-defined date header", context do
    response = Req.head!(context.req, url: "/date_header_test")

    assert response.status == 200

    assert response.headers == %{
             "vary" => ["accept-encoding"],
             "cache-control" => ["max-age=0, private, must-revalidate"],
             "date" => ["Tue, 27 Sep 2022 07:17:32 GMT"]
           }
  end

  def date_header_test(conn) do
    conn
    |> put_resp_header("date", "Tue, 27 Sep 2022 07:17:32 GMT")
    |> send_resp(200, <<>>)
  end

  test "omitting HEAD response content-length", context do
    response = Req.head!(context.req, url: "/head_omit_content_length_test")

    assert response.status == 200
    assert response.headers["content-length"] == nil
  end

  def head_omit_content_length_test(conn) do
    conn |> send_resp(200, <<>>)
  end

  test "respecting user-defined HEAD response content-length", context do
    response = Req.head!(context.req, url: "/head_preserve_content_length_test")

    assert response.status == 200
    assert response.headers["content-length"] == ["6"]
  end

  def head_preserve_content_length_test(conn) do
    conn
    |> put_resp_header("content-length", "6")
    |> send_resp(200, <<>>)
  end

  test "respecting user-defined HEAD response content-length: 0", context do
    response = Req.head!(context.req, url: "/head_zero_content_length_test")

    assert response.status == 200
    assert response.headers["content-length"] == ["0"]
  end

  def head_zero_content_length_test(conn) do
    conn
    |> put_resp_header("content-length", "0")
    |> send_resp(200, <<>>)
  end

  test "overriding incorrect user-defined HEAD response content-length", context do
    response = Req.head!(context.req, url: "/head_override_content_length_test")

    assert response.status == 200
    assert response.headers["content-length"] == ["2"]
  end

  def head_override_content_length_test(conn) do
    conn
    |> put_resp_header("content-length", "6")
    |> send_resp(200, "OK")
  end

  test "sending a body", context do
    response = Req.get!(context.req, url: "/body_test")

    assert response.status == 200
    assert response.body == "OK"
  end

  def body_test(conn) do
    conn |> send_resp(200, "OK")
  end

  test "sending a body as iolist", context do
    response = Req.get!(context.req, url: "/iolist_body_test")

    assert response.status == 200
    assert response.body == "OK"
  end

  def iolist_body_test(conn) do
    conn |> send_resp(200, ["O", "K"])
  end

  test "lazy sending a body", context do
    response = Req.get!(context.req, url: "/lazy_body_test")

    assert response.status == 200
    assert response.body == "OK"
  end

  def lazy_body_test(conn) do
    conn |> resp(200, "OK")
  end

  @tag :capture_log
  test "sending a body from another process works as expected", context do
    response = Req.get!(context.req, url: "/other_process_send_body")

    assert response.status == 200
  end

  def other_process_send_body(conn) do
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

  test "sending a chunk", context do
    response = Req.get!(context.req, url: "/chunk_test")

    assert response.status == 200
    assert response.body == "OKOK"
  end

  def chunk_test(conn) do
    conn
    |> send_chunked(200)
    |> chunk("OK")
    |> elem(1)
    |> chunk("OK")
    |> elem(1)
  end

  @tag :capture_log
  test "setting a chunked response from another process works as expected", context do
    response = Req.get!(context.req, url: "/other_process_set_chunk")

    assert response.status == 200
  end

  def other_process_set_chunk(conn) do
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
  test "sending a chunk from another process works as expected", context do
    response = Req.get!(context.req, url: "/other_process_send_chunk")

    assert response.status == 200
  end

  def other_process_send_chunk(conn) do
    conn = conn |> send_chunked(200)

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

  describe "upgrade handling" do
    @tag :capture_log
    test "raises an ArgumentError on unsupported upgrades", context do
      {:ok, response} = Req.get(context.req, url: "/upgrade_unsupported")
      assert response.status == 500

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (ArgumentError) upgrade to unsupported not supported by Bandit.Adapter"
    end

    def upgrade_unsupported(conn) do
      conn
      |> upgrade_adapter(:unsupported, nil)
      |> send_resp(200, "Not supported")
    end
  end

  @tag :capture_log
  test "raises a Plug.Conn.NotSentError if nothing was set in the conn", context do
    {:ok, response} = Req.get(context.req, url: "/noop")
    assert response.status == 500

    assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

    assert msg =~
             "** (Plug.Conn.NotSentError) a response was neither set nor sent from the connection"
  end

  def noop(conn), do: conn

  @tag :capture_log
  test "raises an error if the conn returns garbage", context do
    {:ok, response} = Req.get(context.req, url: "/garbage")
    assert response.status == 500

    assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

    assert msg =~
             "** (RuntimeError) Expected Elixir.HTTP2PlugTest.call/2 to return %Plug.Conn{} but got: :boom"
  end

  def garbage(_conn), do: :boom

  test "writes out a sent file for the entire file", context do
    response = Req.get!(context.req, url: "/send_full_file")

    assert response.status == 200
    assert response.headers["content-length"] == ["6"]
    assert response.body == "ABCDEF"
  end

  def send_full_file(conn) do
    conn
    |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
  end

  test "writes out a sent file for parts of a file", context do
    response = Req.get!(context.req, url: "/send_file?offset=1&length=5")

    assert response.status == 200
    assert response.body == "BCDEF"
  end

  @large_file_path Path.join([__DIR__, "../../support/sendfile_large"])

  test "sending a large file greater than 2048 bytes", context do
    response = Req.get!(context.req, url: "/large_file_test")

    assert response.status == 200
    assert response.body == File.read!(@large_file_path)
  end

  def large_file_test(conn) do
    conn
    |> send_file(200, @large_file_path, 0, :all)
  end

  @tag :capture_log
  test "errors out if asked to read beyond the file", context do
    {:ok, response} = Req.get(context.req, url: "/send_file?offset=1&length=3000")
    assert response.status == 500

    assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
    assert msg =~ "** (RuntimeError) Cannot read 3000 bytes starting at 1"
  end

  def send_file(conn) do
    conn = fetch_query_params(conn)

    conn
    |> send_file(
      200,
      Path.join([__DIR__, "../../support/sendfile"]),
      String.to_integer(conn.params["offset"]),
      String.to_integer(conn.params["length"])
    )
  end

  @tag :capture_log
  test "sending a file from another process works as expected", context do
    response = Req.get!(context.req, url: "/other_process_send_file")

    assert response.status == 200
  end

  def other_process_send_file(conn) do
    error =
      Task.async(fn ->
        try do
          send_file(conn, 200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
        rescue
          error -> error
        end
      end)
      |> Task.await()

    assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

    send_resp(conn, 200, "OK")
  end

  test "sending a body blocks on connection flow control", context do
    context =
      context
      |> https_server(thousand_island_options: [read_timeout: 500])
      |> Enum.into(context)

    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/blocking_test", context.port)
    SimpleH2Client.successful_response?(socket, 1, false)

    # Give ourselves lots of room on the stream so we can focus on the
    # effect of the connection window
    SimpleH2Client.send_window_update(socket, 1, 1_000_000)

    # Consume 6 10k chunks
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)

    # Consume 1 5_535 byte chunk
    {:ok, 1, false, chunk} = SimpleH2Client.recv_body(socket)
    assert byte_size(chunk) == 5_535

    # Sleep a bit before updating the window (we expect to see this delay in
    # the timings for the blocked chunk below)
    Process.sleep(100)

    # Grow the connection window by 100 and observe we now unlocked the server
    SimpleH2Client.send_window_update(socket, 0, 100_000)

    # This will return the 10k - 5_535 byte remainder of the 7th chunk
    SimpleH2Client.recv_body(socket)

    # This will return our stats. Run some tests on them
    {:ok, 1, false, timings} = SimpleH2Client.recv_body(socket)
    [non_blocked, blocked] = Jason.decode!(timings)

    # Ensure the non-blocked chunks (60k worth) were *much* faster than the
    # blocked chunk (which only did 10k)
    assert non_blocked < 50
    assert blocked > 100
    assert blocked < 250
  end

  test "sending a body blocks on stream flow control", context do
    context =
      context
      |> https_server(thousand_island_options: [read_timeout: 500])
      |> Enum.into(context)

    socket = SimpleH2Client.setup_connection(context)

    # Give ourselves lots of room on the connection so we can focus on the
    # effect of the stream window
    SimpleH2Client.send_window_update(socket, 0, 1_000_000)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/blocking_test", context.port)
    SimpleH2Client.successful_response?(socket, 1, false)

    # Consume 6 10k chunks
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)
    SimpleH2Client.recv_body(socket)

    # Consume 1 5_535 byte chunk
    {:ok, 1, false, chunk} = SimpleH2Client.recv_body(socket)
    assert byte_size(chunk) == 5_535

    # Sleep a bit before updating the window (we expect to see this delay in
    # the timings for the blocked chunk below)
    Process.sleep(100)

    # Grow the stream window by 100 and observe we now unlocked the server
    SimpleH2Client.send_window_update(socket, 1, 100_000)

    # This will return the 10k - 5_535 byte remainder of the 7th chunk
    SimpleH2Client.recv_body(socket)

    # This will return our stats. Run some tests on them
    {:ok, 1, false, timings} = SimpleH2Client.recv_body(socket)
    [non_blocked, blocked] = Jason.decode!(timings)

    # Ensure the the non-blocked chunks (60k worth) were *much* faster than the
    # blocked chunk (which only did 10k)
    assert non_blocked < 50
    assert blocked > 100
    assert blocked < 250
  end

  def blocking_test(conn) do
    data = String.duplicate("0123456789", 1_000)

    start_time = System.monotonic_time(:millisecond)

    # This entire block of writes will proceed without blocking
    conn = conn |> send_chunked(200)
    {:ok, conn} = conn |> chunk(data)
    {:ok, conn} = conn |> chunk(data)
    {:ok, conn} = conn |> chunk(data)
    {:ok, conn} = conn |> chunk(data)
    {:ok, conn} = conn |> chunk(data)
    {:ok, conn} = conn |> chunk(data)

    mid_time = System.monotonic_time(:millisecond)

    # This write will block until the client extends the send window
    {:ok, conn} = conn |> chunk(data)

    end_time = System.monotonic_time(:millisecond)

    # Send timings of how long the unblocked writes took (to write 60k) and
    # how long the blocked write took (to write a measly 10k)
    {:ok, conn} = conn |> chunk(Jason.encode!([mid_time - start_time, end_time - mid_time]))

    conn
  end

  test "sending zero byte bodies does not block on connection or stream flow control", context do
    context =
      context
      |> https_server(thousand_island_options: [read_timeout: 500])
      |> Enum.into(context)

    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_empty_body", context.port)
    assert {:ok, 1, false, _headers, ctx} = SimpleH2Client.recv_headers(socket)
    {:ok, 1, true, ""} = SimpleH2Client.recv_body(socket)

    SimpleH2Client.send_simple_headers(socket, 3, :get, "/send_empty_body", context.port)
    assert {:ok, 3, false, _headers, ctx} = SimpleH2Client.recv_headers(socket, ctx)
    {:ok, 3, true, ""} = SimpleH2Client.recv_body(socket)

    SimpleH2Client.send_simple_headers(socket, 5, :get, "/send_empty_body", context.port)
    assert {:ok, 5, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket, ctx)
    {:ok, 5, true, ""} = SimpleH2Client.recv_body(socket)
  end

  def send_empty_body(conn) do
    send_resp(conn, 200, "")
  end

  test "does not send window updates on closed streams that are never read", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :post, "/no_read", context.port)
    SimpleH2Client.send_body(socket, 1, true, "ABCDEF")

    assert [
             SimpleH2Client.recv_frame(socket),
             SimpleH2Client.recv_frame(socket),
             SimpleH2Client.recv_frame(socket)
           ]
           ~> in_any_order([
             {:ok, :window_update, term(), 0, term()},
             {:ok, :headers, term(), 1, term()},
             {:ok, :data, term(), 1, term()}
           ])

    assert SimpleH2Client.connection_alive?(socket)
  end

  def no_read(conn) do
    conn |> send_resp(200, <<>>)
  end

  test "sending informational responses", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_inform", context.port)

    assert {:ok, 1, false, [{":status", "100"}, {"date", date}, {"x-from", "inform"}], ctx} =
             SimpleH2Client.recv_headers(socket)

    assert {:ok, 1, false, _, _} = SimpleH2Client.recv_headers(socket, ctx)
    assert {:ok, 1, true, "Informer"} = SimpleH2Client.recv_body(socket)

    assert DateHelpers.valid_date_header?(date)

    assert SimpleH2Client.connection_alive?(socket)
  end

  def send_inform(conn) do
    conn = conn |> inform(100, [{:"x-from", "inform"}])
    conn |> send_resp(200, "Informer")
  end

  @tag :capture_log
  test "sending an inform response from another process works as expected", context do
    response = Req.get!(context.req, url: "/other_process_send_inform")

    assert response.status == 200
  end

  def other_process_send_inform(conn) do
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

  test "reading HTTP version", context do
    response = Req.get!(context.req, url: "/report_version")

    assert response.status == 200
    assert response.body == "HTTP/2"
  end

  def report_version(conn) do
    send_resp(conn, 200, conn |> get_http_protocol() |> to_string())
  end

  test "reading peer data", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/peer_data", context.port)
    SimpleH2Client.recv_headers(socket)
    {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
    {:ok, {ip, port}} = Transport.sockname(socket)

    assert body == inspect(%{address: ip, port: port, ssl_cert: nil})
  end

  def peer_data(conn) do
    send_resp(conn, 200, conn |> get_peer_data() |> inspect())
  end

  test "reading sock data", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/sock_data", context.port)
    SimpleH2Client.recv_headers(socket)
    {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
    {:ok, {ip, port}} = Transport.peername(socket)

    assert body == inspect(%{address: ip, port: port})
  end

  def sock_data(conn) do
    send_resp(conn, 200, conn |> get_sock_data() |> inspect())
  end

  test "reading ssl data", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/ssl_data", context.port)
    SimpleH2Client.recv_headers(socket)
    {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)

    assert body =~ ~r/protocol/
    assert body =~ ~r/ciphers/
  end

  def ssl_data(conn) do
    body =
      conn
      |> get_ssl_data()
      |> Keyword.take([:protocol, :ciphers])
      |> inspect(limit: :infinity)

    send_resp(conn, 200, body)
  end

  test "silently accepts EXIT messages from normally terminating spawned processes", context do
    response = Req.get!(context.req, url: "/spawn_child")
    assert response.status == 204

    refute_receive {:log, %{level: :error}}
  end

  def spawn_child(conn) do
    spawn_link(fn -> exit(:normal) end)
    Process.sleep(10)
    send_resp(conn, 204, "")
  end

  describe "telemetry" do
    test "it should send `start` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :start], measurements, metadata}, 500

      assert measurements ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_200"]),
               plug: {__MODULE__, []}
             }
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "it should send `stop` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 0,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_200"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for requests with no request body",
         context do
      Req.post!(context.req, url: "/do_read_body", body: <<>>)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 0,
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
               plug: {__MODULE__, []}
             }
    end

    def do_read_body(conn) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "OK")
    end

    test "it should add req metrics to `stop` events for requests with request body", context do
      Req.post!(context.req, url: "/do_read_body", body: String.duplicate("a", 80))

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 80,
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for requests with content encoding",
         context do
      Req.post!(context.req,
        url: "/do_read_body",
        body: String.duplicate("a", 80),
        headers: [{"accept-encoding", "gzip"}]
      )

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 80,
               resp_uncompressed_body_bytes: 2,
               resp_body_bytes: 22,
               resp_compression_method: "gzip",
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add resp metrics to `stop` events for chunked responses", context do
      Req.get!(context.req, url: "/chunk_test")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 4,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["chunk_test"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add resp metrics to `stop` events for sendfile responses", context do
      Req.get!(context.req, url: "/send_full_file")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 6,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_full_file"]),
               plug: {__MODULE__, []}
             }
    end

    @tag :capture_log
    test "it should send `stop` events for malformed requests", context do
      socket = SimpleH2Client.setup_connection(context)

      # Take uppercase header example from H2Spec
      headers =
        <<130, 135, 68, 137, 98, 114, 209, 65, 226, 240, 123, 40, 147, 65, 139, 8, 157, 92, 11,
          129, 112, 220, 109, 199, 26, 127, 64, 6, 88, 45, 84, 69, 83, 84, 2, 111, 107>>

      SimpleH2Client.send_frame(socket, 1, 5, 1, headers)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native))
             }

      assert metadata
             ~> %{
               plug: {__MODULE__, []},
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               error: string()
             }
    end

    @tag :capture_log
    test "it should send `exception` events for raising requests", context do
      Req.get(context.req, url: "/raise_error")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["raise_error"]),
               plug: {__MODULE__, []},
               kind: :exit,
               exception: %RuntimeError{message: "boom"},
               stacktrace: list()
             }
    end

    def raise_error(_conn) do
      raise "boom"
    end

    @tag :capture_log
    test "it should send `exception` events for throwing requests", context do
      Req.get!(context.req, url: "/uncaught_throw")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["uncaught_throw"]),
               plug: {__MODULE__, []},
               kind: :throw,
               exception: "thrown",
               stacktrace: list()
             }
    end

    def uncaught_throw(_conn) do
      throw("thrown")
    end

    @tag :capture_log
    test "it should send `exception` events for exiting requests", context do
      Req.get!(context.req, url: "/uncaught_exit")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["uncaught_exit"]),
               plug: {__MODULE__, []},
               kind: :exit,
               exception: "exited",
               stacktrace: list()
             }
    end

    def uncaught_exit(_conn) do
      exit("exited")
    end
  end
end
