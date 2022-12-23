defmodule HTTP1RequestTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers
  use FinchHelpers

  import ExUnit.CaptureLog

  setup :http_server
  setup :finch_http1_client

  describe "invalid requests" do
    @tag capture_log: true
    test "returns a 400 if the request cannot be parsed", context do
      client = SimpleHTTP1Client.tcp_client(context)
      :gen_tcp.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    @tag capture_log: true
    test "returns a 400 if the request has an invalid http version", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "./../non_absolute_path", ["host: localhost"], "0.9")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "origin-form request target (RFC9112§3.2.1)" do
    test "derives scheme from underlying transport", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["scheme"] == "http"
    end

    test "derives host from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "banana"
    end

    @tag capture_log: true
    test "returns 400 if no host header set in HTTP/1.1", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components")
      assert {:ok, "400 Bad Request", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
    end

    test "sets a blank host if no host header set in HTTP/1.0", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", [], "1.0")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == ""
    end

    test "derives port from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana:1234"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == 1234
    end

    @tag capture_log: true
    test "returns 400 if port cannot be parsed from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana:-1234"])
      assert {:ok, "400 Bad Request", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
    end

    test "derives port from underlying transport if no port specified in host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == context[:port]
    end

    test "derives port from underlying transport if no host header set in HTTP/1.0", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", [], "1.0")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == context[:port]
    end

    test "sets path and query string properly when no query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "sets path and query string properly when query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components?a=b", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "ignores fragment when no query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components#nope", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "ignores fragment when query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components?a=b#nope", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "handles query strings with question mark characters in them", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components?a=b?c=d", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b?c=d"
    end

    def echo_components(conn) do
      send_resp(
        conn,
        200,
        conn |> Map.take([:scheme, :host, :port, :path_info, :query_string]) |> Jason.encode!()
      )
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
  end

  describe "absolute-form request target (RFC9112§3.2.2)" do
    test "derives scheme from underlying transport", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["scheme"] == "http"
    end

    @tag capture_log: true
    test "returns 400 if URI scheme does not match the transport", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "https://banana/echo_components")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "derives host from the URI, even if it differs from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components", ["host: orange"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "banana"
    end

    @tag capture_log: true
    test "does not require a host header set in HTTP/1.1 (RFC9112§3.2.2)", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "banana"
    end

    test "derives port from the URI, even if it differs from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "http://banana:1234/echo_components", [
        "host: banana:2345"
      ])

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == 1234
    end

    test "derives port from underlying transport if no port specified in the URI", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == context[:port]
    end

    test "sets path and query string properly when no query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "sets path and query string properly when query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components?a=b", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "ignores fragment when no query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components#nope", ["host: banana"])

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "ignores fragment when query string is present", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components?a=b#nope", [
        "host: banana"
      ])

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "handles query strings with question mark characters in them", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components?a=b?c=d", [
        "host: banana"
      ])

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b?c=d"
    end
  end

  describe "authority-form request target (RFC9112§3.2.3)" do
    @tag capture_log: true
    test "returns 400 for authority-form / CONNECT requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "CONNECT", "www.example.com:80", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "asterisk-form request target (RFC9112§3.2.4)" do
    @tag capture_log: true
    test "parse global OPTIONS path correctly", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "OPTIONS", "*", ["host: localhost:1234"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["path_info"] == ["*"]
    end

    def unquote(:*)(conn) do
      echo_components(conn)
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
          String.duplicate("0123456789", 800_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("0123456789", 800_000)
      send_resp(conn, 200, "OK")
    end

    # Success case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    test "reads a content-length with multiple content-lengths encoded body properly", context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_body_with_multiple_content_length",
          [{"connection", "close"}, {"content-length", "8000000,8000000,8000000"}],
          String.duplicate("a", 8_000_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_body_with_multiple_content_length(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000,8000000,8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    # Error case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    @tag capture_log: true
    test "rejects a request with non-matching multiple content lengths", context do
      # Use a smaller body size to avoid raciness in reading the response
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_body_with_multiple_content_length",
          [{"connection", "close"}, {"content-length", "8000,8001,8000"}],
          String.duplicate("a", 8_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 400
    end

    @tag capture_log: true
    test "rejects a request with negative content-length", context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/negative_content_length",
          [{"content-length", "-321"}, {"connection", "close"}],
          String.duplicate("a", 1_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 400
    end

    @tag capture_log: true
    test "rejects a request with non-integer content length", context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_body_with_multiple_content_length",
          [{"connection", "close"}, {"content-length", "foo"}],
          String.duplicate("a", 8_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 400
    end

    test "reads a content-length encoded body properly when more of it arrives than we want to read",
         context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_big_body",
          [{"connection", "close"}],
          String.duplicate("0123456789", 800_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_big_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:more, body, conn} = Plug.Conn.read_body(conn, length: 1000)
      assert body == String.duplicate("0123456789", 100)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("0123456789", 800_000 - 100)
      send_resp(conn, 200, "OK")
    end

    test "reads a chunked body properly", context do
      stream =
        Stream.repeatedly(fn -> String.duplicate("0123456789", 100_000) end)
        |> Stream.take(8)

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
      assert body == String.duplicate("0123456789", 800_000)
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

  describe "response headers" do
    test "writes out a response with a valid date header", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_200")
        |> Finch.request(context[:finch_name])

      assert response.status == 200

      date = Bandit.Headers.get_header(response.headers, "date")
      assert TestHelpers.valid_date_header?(date)
    end

    test "returns user-defined date header instead of internal version", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/date_header")
        |> Finch.request(context[:finch_name])

      assert response.status == 200

      date = Bandit.Headers.get_header(response.headers, "date")
      assert date == "Tue, 27 Sep 2022 07:17:32 GMT"
    end

    def date_header(conn) do
      conn
      |> put_resp_header("date", "Tue, 27 Sep 2022 07:17:32 GMT")
      |> send_resp(200, "OK")
    end
  end

  describe "response body" do
    test "writes out a response with no content-length header for 204 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_204", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 204
      assert response.body == ""
      assert is_nil(Bandit.Headers.get_header(response.headers, "content-length"))
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
      assert is_nil(Bandit.Headers.get_header(response.headers, "content-length"))
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
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
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
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
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
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
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

      assert Bandit.Headers.get_header(response.headers, "transfer-encoding") == "chunked"
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
      assert Bandit.Headers.get_header(response.headers, "content-length") == "6"
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
      assert Bandit.Headers.get_header(response.headers, "content-length") == "3"
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

    @tag capture_log: true
    test "returns a 500 if the plug does not return anything", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/noop")
        |> Finch.request(context[:finch_name])

      assert response.status == 500
    end

    def noop(conn) do
      conn
    end

    @tag capture_log: true
    test "returns a 500 if the plug does not return a conn", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/return_garbage")
        |> Finch.request(context[:finch_name])

      assert response.status == 500
    end

    def return_garbage(_conn) do
      :nope
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
