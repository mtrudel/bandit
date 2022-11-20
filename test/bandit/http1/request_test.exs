defmodule HTTP1RequestTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers
  use FinchHelpers

  import ExUnit.CaptureLog

  setup :http_server
  setup :finch_http1_client

  describe "request line" do
    @tag capture_log: true
    test "returns a 400 if the request cannot be parsed", context do
      client = SimpleHTTP1Client.tcp_client(context)
      :gen_tcp.send(client, "GET / HTTP/1.0\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    @tag capture_log: true
    test "returns a 400 if the request has an invalid http version", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "./../non_absolute_path", ["host: localhost"], "0.9")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    @tag capture_log: true
    test "returns 400 if a non-absolute path is send", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "./../non_absolute_path", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    @tag capture_log: true
    test "returns 400 if path has no leading slash", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "path_without_leading_slash", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "handle absoluteURI as path correctly", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "http://example-host.com:1337/absolute_uri_path", [
        "host: example-host.com:1337"
      ])

      assert {:ok, "200 OK", _headers, "absolute_uri_path"} = SimpleHTTP1Client.recv_reply(client)
    end

    def absolute_uri_path(conn) do
      assert conn.host == "example-host.com"
      assert conn.port == 1337
      assert conn.path_info == ["absolute_uri_path"]
      send_resp(conn, 200, "absolute_uri_path")
    end

    @tag capture_log: true
    test "handle global OPTIONS request correctly", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "OPTIONS", "*", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "options"} = SimpleHTTP1Client.recv_reply(client)
    end

    def unquote(:*)(conn) do
      assert conn.request_path == "*"
      assert conn.path_info == ["*"]
      send_resp(conn, 200, "options")
    end

    @tag capture_log: true
    test "returns 400 for authority-form / CONNECT requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "CONNECT", "www.example.com:80", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "request headers" do
    test "reads headers properly", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/expect_headers/a//b/c?abc=def", [
          {"X-Fruit", "banana"},
          {"connection", "close"}
        ])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_headers(conn) do
      assert conn.request_path == "/expect_headers/a//b/c"
      assert conn.path_info == ["expect_headers", "a", "b", "c"]
      assert conn.query_string == "abc=def"
      assert conn.method == "GET"
      assert conn.remote_ip == {127, 0, 0, 1}
      assert Plug.Conn.get_req_header(conn, "x-fruit") == ["banana"]
      # make iodata explicit
      send_resp(conn, 200, ["O", "K"])
    end
  end

  describe "request body" do
    test "reads a zero length body properly", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/expect_no_body", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_no_body(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ""
      send_resp(conn, 200, "OK")
    end

    test "reads a content-length encoded body properly", context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_body",
          [{"connection", "close"}],
          String.duplicate("a", 8_000_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    test "reads a content-length encoded body properly when more of it arrives than we want to read",
         context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_big_body",
          [{"connection", "close"}],
          String.duplicate("a", 8_000_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_big_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:more, body, conn} = Plug.Conn.read_body(conn, length: 1000)
      assert body == String.duplicate("a", 1000)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000 - 1000)
      send_resp(conn, 200, "OK")
    end

    test "reads a chunked body properly", context do
      stream = Stream.repeatedly(fn -> String.duplicate("a", 1_000_000) end) |> Stream.take(8)

      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_chunked_body",
          [{"connection", "close"}],
          {:stream, stream}
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_chunked_body(conn) do
      assert Plug.Conn.get_req_header(conn, "transfer-encoding") == ["chunked"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
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
  end

  describe "upgrade handling" do
    test "raises an ArgumentError on unsupported upgrades", context do
      errors =
        capture_log(fn ->
          {:ok, response} =
            Finch.build(:get, context[:base] <> "/upgrade_unsupported", [{"connection", "close"}])
            |> Finch.request(context[:finch_name])

          assert response.status == 500

          Process.sleep(100)
        end)

      assert errors =~
               "(ArgumentError) upgrade to unsupported not supported by Bandit.HTTP1.Adapter"
    end

    def upgrade_unsupported(conn) do
      conn
      |> upgrade_adapter(:unsupported, nil)
      |> send_resp(200, "Not supported")
    end

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but the connection is not a valid upgrade",
         context do
      errors =
        capture_log(fn ->
          {:ok, response} =
            Finch.build(:get, context[:base] <> "/upgrade_websocket", [{"connection", "close"}])
            |> Finch.request(context[:finch_name])

          assert response.status == 400
          assert response.body == "Not a valid WebSocket upgrade request"

          Process.sleep(100)
        end)

      assert errors =~ "Not a valid WebSocket upgrade request"
    end

    defmodule MyNoopWebSock do
      use NoopWebSock
    end

    def upgrade_websocket(conn) do
      # In actual use, it's the caller's responsibility to ensure the upgrade is valid before
      # calling upgrade_adapter
      conn
      |> upgrade_adapter(:websocket, {MyNoopWebSock, [], []})
    end
  end

  describe "response handling" do
    test "writes out a response with no content-length header for 204 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_204", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 204
      assert response.body == ""
      assert is_nil(List.keyfind(response.headers, "content-length", 0))
    end

    def send_204(conn) do
      send_resp(conn, 204, "")
    end

    test "writes out a response with no content-length header for 304 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_304", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 304
      assert response.body == ""
      assert is_nil(List.keyfind(response.headers, "content-length", 0))
    end

    def send_304(conn) do
      send_resp(conn, 304, "")
    end

    test "writes out a response with zero content-length for 200 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_200")
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == ""
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "0"}
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "writes out a response with zero content-length for 301 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_301")
        |> Finch.request(context[:finch_name])

      assert response.status == 301
      assert response.body == ""
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "0"}
    end

    def send_301(conn) do
      send_resp(conn, 301, "")
    end

    test "writes out a response with zero content-length for 401 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_401")
        |> Finch.request(context[:finch_name])

      assert response.status == 401
      assert response.body == ""
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "0"}
    end

    def send_401(conn) do
      send_resp(conn, 401, "")
    end

    test "writes out a chunked response", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_chunked_200", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"

      assert List.keyfind(response.headers, "transfer-encoding", 0) ==
               {"transfer-encoding", "chunked"}
    end

    def send_chunked_200(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk("OK")

      conn
    end

    test "writes out a sent file for the entire file with content length", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_full_file", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "ABCDEF"
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "6"}
    end

    def send_full_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "writes out a sent file for parts of a file with content length", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_file?offset=1&length=3", [
          {"connection", "close"}
        ])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "BCD"
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "3"}
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

    test "returns user-defined date header instead of internal version", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/date_header")
        |> Finch.request(context[:finch_name])

      assert response.status == 200

      assert List.keyfind(response.headers, "date", 0) |> elem(1) ==
               "Tue, 27 Sep 2022 07:17:32 GMT"
    end

    def date_header(conn) do
      conn
      |> put_resp_header("date", "Tue, 27 Sep 2022 07:17:32 GMT")
      |> send_resp(200, "OK")
    end
  end

  describe "abnormal handler processes" do
    @tag capture_log: true
    test "returns a 500 if the plug raises an exception", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/raise_error")
        |> Finch.request(context[:finch_name])

      assert response.status == 500
    end

    def raise_error(_conn) do
      raise "boom"
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
      # a single GenServer call & will complete before the handler process handles
      # the handle_info call returned by the spawned process. Look at the logged
      # errors instead
      assert errors == ""
    end

    def spawn_child(conn) do
      spawn_link(fn -> exit(:normal) end)
      send_resp(conn, 204, "")
    end
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
    # a single GenServer call & will complete before the handler process handles
    # the handle_info call returned by the spawned process. Look at the logged
    # errors instead
    assert errors =~ ~r[\[error\] GenServer .* terminating]
  end

  def spawn_abnormal_child(conn) do
    spawn_link(fn -> exit(:abnormal) end)
    send_resp(conn, 204, "")
  end
end
