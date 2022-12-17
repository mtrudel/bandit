defmodule HTTP2PlugTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers
  use FinchHelpers

  import ExUnit.CaptureLog

  setup :https_server
  setup :finch_h2_client

  test "reading request headers", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/header_read_test", [{"X-Request-Header", "Request"}])
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def header_read_test(conn) do
    assert get_req_header(conn, "x-request-header") == ["Request"]

    conn |> send_resp(200, <<>>)
  end

  test "request headers do not include pseudo headers", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/no_pseudo_header")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def no_pseudo_header(conn) do
    assert get_req_header(conn, ":scheme") == []

    conn |> send_resp(200, <<>>)
  end

  test "reading request body when there is no body sent", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/empty_body_read")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def empty_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == ""
    conn |> send_resp(200, body)
  end

  test "reading request body when there is a simple body sent", context do
    {:ok, response} =
      Finch.build(:post, context[:base] <> "/simple_body_read", [], "OK")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def simple_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == "OK"
    conn |> send_resp(200, body)
  end

  test "reading request body multiple times works as expected", context do
    {:ok, response} =
      Finch.build(:post, context[:base] <> "/multiple_body_read", [], "OK")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def multiple_body_read(conn) do
    {:ok, body, conn} = read_body(conn)
    assert body == "OK"
    assert_raise(Bandit.BodyAlreadyReadError, fn -> read_body(conn) end)
    conn |> send_resp(200, body)
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

    assert SimpleH2Client.successful_response?(socket, 1, true)
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
    Process.sleep(500)
    SimpleH2Client.send_body(socket, 1, true, "BC")

    assert SimpleH2Client.successful_response?(socket, 1, true)
  end

  def timeout_body_read(conn) do
    {:more, body, conn} = read_body(conn, read_timeout: 100)
    assert body == "A"
    {:ok, body, conn} = read_body(conn)
    assert body == "BC"
    conn |> send_resp(200, <<>>)
  end

  test "writing response headers", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/header_write_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200

    assert [
             {"date", date},
             {"cache-control", "max-age=0, private, must-revalidate"},
             {"X-Response-Header", "Response"}
           ] = response.headers

    assert TestHelpers.valid_date_header?(date)
  end

  def header_write_test(conn) do
    conn
    |> put_resp_header("X-Response-Header", "Response")
    |> send_resp(200, <<>>)
  end

  test "writing user-defined date header", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/date_header_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200

    assert [
             {"cache-control", "max-age=0, private, must-revalidate"},
             {"date", "Tue, 27 Sep 2022 07:17:32 GMT"}
           ] = response.headers
  end

  def date_header_test(conn) do
    conn
    |> put_resp_header("date", "Tue, 27 Sep 2022 07:17:32 GMT")
    |> send_resp(200, <<>>)
  end

  test "sending a body", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/body_test") |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def body_test(conn) do
    conn |> send_resp(200, "OK")
  end

  test "sending a body as iolist", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/iolist_body_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def iolist_body_test(conn) do
    conn |> send_resp(200, ["O", "K"])
  end

  test "lazy sending a body", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/lazy_body_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def lazy_body_test(conn) do
    conn |> resp(200, "OK")
  end

  test "sending a chunk", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/chunk_test") |> Finch.request(context[:finch_name])

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

  describe "upgrade handling" do
    test "raises an ArgumentError on unsupported upgrades", context do
      errors =
        capture_log(fn ->
          response =
            Finch.build(:get, context[:base] <> "/upgrade_unsupported")
            |> Finch.request(context[:finch_name])

          assert {:error, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} =
                   response
        end)

      assert errors =~
               "(ArgumentError) upgrade to unsupported not supported by Bandit.HTTP2.Adapter"
    end

    def upgrade_unsupported(conn) do
      conn
      |> upgrade_adapter(:unsupported, nil)
      |> send_resp(200, "Not supported")
    end
  end

  test "raises a Plug.Conn.NotSentError if nothing was set in the conn", context do
    errors =
      capture_log(fn ->
        response =
          Finch.build(:get, context[:base] <> "/noop")
          |> Finch.request(context[:finch_name])

        assert {:error, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} =
                 response
      end)

    assert errors =~
             "%Plug.Conn.NotSentError{message: \"a response was neither set nor sent from the connection\"}"
  end

  def noop(conn), do: conn

  test "raises an error if the conn returns garbage", context do
    errors =
      capture_log(fn ->
        response =
          Finch.build(:get, context[:base] <> "/garbage")
          |> Finch.request(context[:finch_name])

        assert {:error, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} =
                 response
      end)

    assert errors =~
             "%RuntimeError{message: \"Expected Elixir.HTTP2PlugTest.call/2 to return %Plug.Conn{} but got: :boom\"}"
  end

  def garbage(_conn), do: :boom

  test "writes out a sent file for the entire file", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/send_full_file")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "ABCDEF"
  end

  def send_full_file(conn) do
    conn
    |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
  end

  test "writes out a sent file for parts of a file", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/send_file?offset=1&length=3")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "BCD"
  end

  @large_file_path Path.join([__DIR__, "../../support/sendfile_large"])

  test "sending a large file greater than 2048 bytes", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/large_file_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == File.read!(@large_file_path)
  end

  def large_file_test(conn) do
    conn
    |> send_file(200, @large_file_path, 0, :all)
  end

  test "errors out if asked to read beyond the file", context do
    errors =
      capture_log(fn ->
        response =
          Finch.build(:get, context[:base] <> "/send_file?offset=1&length=3000")
          |> Finch.request(context[:finch_name])

        assert {:error, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} =
                 response
      end)

    assert errors =~
             "%RuntimeError{message: \"Cannot read 3000 bytes starting at 1"
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

  test "sending a body blocks on connection flow control", context do
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

    # Ensure the the non-blocked chunks (60k worth) were *much* faster than the
    # blocked chunk (which only did 10k)
    assert non_blocked < 20
    assert blocked > 100
    assert blocked < 300
  end

  test "sending a body blocks on stream flow control", context do
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
    assert non_blocked < 10
    assert blocked > 100
    assert blocked < 200
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

  test "sending informational responses", context do
    socket = SimpleH2Client.setup_connection(context)

    SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_inform", context.port)

    expected_headers = [{":status", "100"}, {"x-from", "inform"}]
    assert {:ok, 1, false, ^expected_headers, ctx} = SimpleH2Client.recv_headers(socket)
    assert {:ok, 1, false, _, _} = SimpleH2Client.recv_headers(socket, ctx)
    assert {:ok, 1, true, "Informer"} = SimpleH2Client.recv_body(socket)

    assert SimpleH2Client.connection_alive?(socket)
  end

  def send_inform(conn) do
    conn = conn |> inform(100, [{"x-from", "inform"}])
    conn |> send_resp(200, "Informer")
  end

  test "reading HTTP version", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/report_version")
      |> Finch.request(context[:finch_name])

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
    {:ok, {ip, port}} = :ssl.sockname(socket)

    assert body == inspect(%{address: ip, port: port, ssl_cert: nil})
  end

  def peer_data(conn) do
    send_resp(conn, 200, conn |> get_peer_data() |> inspect())
  end

  test "silently accepts EXIT messages from normally terminating spwaned processes", context do
    errors =
      capture_log(fn ->
        Finch.build(:get, context[:base] <> "/spawn_child")
        |> Finch.request(context[:finch_name])

        # Let the backing process see & handle the handle_info EXIT message
        Process.sleep(100)
      end)

    # The return value here isn't relevant, since the HTTP call is done within
    # a single Task call & may complete before the spawned process exits. Look
    # at the logged errors instead
    assert errors == ""
  end

  def spawn_child(conn) do
    spawn_link(fn -> exit(:normal) end)
    # Ensure that the spawned process has a chance to exit
    Process.sleep(100)
    send_resp(conn, 204, "")
  end

  test "does not do anything special with EXIT messages from abnormally terminating spwaned processes",
       context do
    errors =
      capture_log(fn ->
        Finch.build(:get, context[:base] <> "/spawn_abnormal_child")
        |> Finch.request(context[:finch_name])

        # Let the backing process see & handle the handle_info EXIT message
        Process.sleep(100)
      end)

    # The return value here isn't relevant, since the HTTP call is done within
    # a single Task call & may complete before the spawned process exits. Look
    # at the logged errors instead
    assert errors =~ ~r[\[error\] Task for stream .* crashed with :abnormal]
  end

  def spawn_abnormal_child(conn) do
    spawn_link(fn -> exit(:abnormal) end)
    # Ensure that the spawned process has a chance to exit
    Process.sleep(100)
    send_resp(conn, 204, "")
  end
end
