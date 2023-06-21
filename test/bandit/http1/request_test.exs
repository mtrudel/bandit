defmodule HTTP1RequestTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers
  use ReqHelpers
  use Machete

  import ExUnit.CaptureLog

  setup :http_server
  setup :req_http1_client

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
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: localhost"], "0.9")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "keepalive requests" do
    test "closes connection after max_requests is reached", context do
      context = http_server(context, http_1_options: [max_requests: 3])
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    test "idle keepalive connections are closed after read_timeout", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: localhost"])
      assert {:ok, "200 OK", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
      Process.sleep(1100)

      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
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

    test "derives host from host header with ipv6 host", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", [
        "host: [FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"
      ])

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"
    end

    test "derives host and port from host header with ipv6 host", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: [::1]:1234"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "[::1]"
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
    test "uses request-line scheme even if it does not match the transport", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "https://banana/echo_components")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["scheme"] == "https"
    end

    test "derives host from the URI, even if it differs from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components", ["host: orange"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "banana"
    end

    # Skip this test since there is a bug in :erlang.decode_packet. See https://github.com/mtrudel/bandit/pull/97
    # This has been fixed upstream in OTP26+; see OTP-18540 for details. Reintroduce this test
    # once we support OTP26+
    @tag :skip
    test "derives ipv6 host from the URI, even if it differs from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "http://[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]/echo_components",
        ["host: orange"]
      )

      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["host"] == "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"
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

  describe "request line limits" do
    @tag capture_log: true
    test "returns 414 for request lines that are too long", context do
      context = http_server(context, http_1_options: [max_request_line_length: 5000])
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", String.duplicate("a", 5000 - 14))

      assert {:ok, "414 Request-URI Too Long", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "request headers" do
    test "reads headers properly", context do
      response =
        Req.get!(context.req,
          url: "/expect_headers/a//b/c?abc=def",
          headers: [{"X-Fruit", "banana"}]
        )

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

    @tag capture_log: true
    test "returns 431 for header lines that are too long", context do
      context = http_server(context, http_1_options: [max_header_length: 5000])
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", [
        "host: localhost",
        "foo: " <> String.duplicate("a", 5000 - 6)
      ])

      assert {:ok, "431 Request Header Fields Too Large", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)
    end

    @tag capture_log: true
    test "returns 431 for too many header lines", context do
      context = http_server(context, http_1_options: [max_header_count: 40])
      client = SimpleHTTP1Client.tcp_client(context)

      headers = for i <- 1..40, do: "header#{i}: foo"
      SimpleHTTP1Client.send(client, "GET", "/echo_components", headers ++ ["host: localhost"])

      assert {:ok, "431 Request Header Fields Too Large", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)
    end
  end

  describe "request body" do
    test "reads a zero length body properly", context do
      response = Req.get!(context.req, url: "/expect_no_body")

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_no_body(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ""
      send_resp(conn, 200, "OK")
    end

    test "reads a content-length encoded body properly", context do
      response =
        Req.post!(context.req, url: "/expect_body", body: String.duplicate("0123456789", 800_000))

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
      response =
        Req.post!(context.req,
          url: "/expect_body_with_multiple_content_length",
          headers: [{"content-length", "8000000,8000000,8000000"}],
          body: String.duplicate("a", 8_000_000)
        )

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_body_with_multiple_content_length(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000,8000000,8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    test "reads only the amount of data specified in content-length", context do
      response =
        Req.post!(context.req,
          url: "/respect_content_length",
          headers: [{"content-length", "20"}],
          body: String.duplicate("a", 100)
        )

      assert response.status == 200
      assert response.body == "OK"
    end

    def respect_content_length(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["20"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 20)
      send_resp(conn, 200, "OK")
    end

    # Error case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    @tag capture_log: true
    test "rejects a request with non-matching multiple content lengths", context do
      # Use a smaller body size to avoid raciness in reading the response
      response =
        Req.post!(context.req,
          url: "/expect_body_with_multiple_content_length",
          headers: [{"content-length", "8000,8001,8000"}],
          body: String.duplicate("a", 8_000)
        )

      assert response.status == 400
    end

    @tag capture_log: true
    test "rejects a request with negative content-length", context do
      response =
        Req.post!(context.req,
          url: "/negative_content_length",
          headers: [{"content-length", "-321"}],
          body: String.duplicate("a", 1_000)
        )

      assert response.status == 400
    end

    @tag capture_log: true
    test "rejects a request with non-integer content length", context do
      response =
        Req.post!(context.req,
          url: "/expect_body_with_multiple_content_length",
          headers: [{"content-length", "foo"}],
          body: String.duplicate("a", 8_000)
        )

      assert response.status == 400
    end

    test "reads a content-length encoded body properly when more of it arrives than we want to read",
         context do
      response =
        Req.post!(context.req,
          url: "/expect_big_body",
          body: String.duplicate("0123456789", 800_000)
        )

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

      response = Req.post!(context.req, url: "/expect_chunked_body", body: {:stream, stream})

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
      response = Req.post!(context.req, url: "/multiple_body_read", body: "OK")

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
          response = Req.get!(context.req, url: "/upgrade_unsupported")

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

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but the connection is not a GET",
         context do
      errors =
        capture_log(fn ->
          client = SimpleHTTP1Client.tcp_client(context)

          SimpleHTTP1Client.send(
            client,
            "POST",
            "/upgrade_websocket",
            [
              "Host: server.example.com",
              "Upgrade: WebSocket",
              "Connection: Upgrade",
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
              "Sec-WebSocket-Version: 13"
            ]
          )

          assert SimpleHTTP1Client.recv_reply(client)
                 ~> {:ok, "400 Bad Request", list(),
                  "WebSocket upgrade failed: error in method check: \"POST\""}

          Process.sleep(100)
        end)

      assert errors =~ "WebSocket upgrade failed: error in method check: \\\"POST\\\""
    end

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but upgrade header is incorrect",
         context do
      errors =
        capture_log(fn ->
          client = SimpleHTTP1Client.tcp_client(context)

          SimpleHTTP1Client.send(
            client,
            "GET",
            "/upgrade_websocket",
            [
              "Host: server.example.com",
              "Upgrade: NOPE",
              "Connection: Upgrade",
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
              "Sec-WebSocket-Version: 13"
            ]
          )

          assert SimpleHTTP1Client.recv_reply(client)
                 ~> {:ok, "400 Bad Request", list(),
                  "WebSocket upgrade failed: error in upgrade_header check: \"Did not find 'websocket' in 'NOPE'\""}

          Process.sleep(100)
        end)

      assert errors =~
               "WebSocket upgrade failed: error in upgrade_header check: \\\"Did not find 'websocket' in 'NOPE'\\\""
    end

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but connection header is incorrect",
         context do
      errors =
        capture_log(fn ->
          client = SimpleHTTP1Client.tcp_client(context)

          SimpleHTTP1Client.send(
            client,
            "GET",
            "/upgrade_websocket",
            [
              "Host: server.example.com",
              "Upgrade: WebSocket",
              "Connection: NOPE",
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
              "Sec-WebSocket-Version: 13"
            ]
          )

          assert SimpleHTTP1Client.recv_reply(client)
                 ~> {:ok, "400 Bad Request", list(),
                  "WebSocket upgrade failed: error in connection_header check: \"Did not find 'upgrade' in 'NOPE'\""}

          Process.sleep(100)
        end)

      assert errors =~
               "WebSocket upgrade failed: error in connection_header check: \\\"Did not find 'upgrade' in 'NOPE'\\\""
    end

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but key header is incorrect",
         context do
      errors =
        capture_log(fn ->
          client = SimpleHTTP1Client.tcp_client(context)

          SimpleHTTP1Client.send(
            client,
            "GET",
            "/upgrade_websocket",
            [
              "Host: server.example.com",
              "Upgrade: WebSocket",
              "Connection: Upgrade",
              "Sec-WebSocket-Version: 13"
            ]
          )

          assert SimpleHTTP1Client.recv_reply(client)
                 ~> {:ok, "400 Bad Request", list(),
                  "WebSocket upgrade failed: error in sec_websocket_key_header check: false"}

          Process.sleep(100)
        end)

      assert errors =~ "WebSocket upgrade failed: error in sec_websocket_key_header check: false"
    end

    test "returns a 400 and errors loudly in cases where an upgrade is indicated but version header is incorrect",
         context do
      errors =
        capture_log(fn ->
          client = SimpleHTTP1Client.tcp_client(context)

          SimpleHTTP1Client.send(
            client,
            "GET",
            "/upgrade_websocket",
            [
              "Host: server.example.com",
              "Upgrade: WebSocket",
              "Connection: Upgrade",
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
              "Sec-WebSocket-Version: 99"
            ]
          )

          assert SimpleHTTP1Client.recv_reply(client)
                 ~> {:ok, "400 Bad Request", list(),
                  "WebSocket upgrade failed: error in sec_websocket_version_header check: [\"99\"]"}

          Process.sleep(100)
        end)

      assert errors =~
               "WebSocket upgrade failed: error in sec_websocket_version_header check: [\\\"99\\\"]"
    end

    test "returns a 400 and errors loudly if websocket support is not enabled", context do
      context = http_server(context, websocket_options: [enabled: false])
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/upgrade_websocket",
        [
          "Host: server.example.com",
          "Upgrade: WebSocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13"
        ]
      )

      assert SimpleHTTP1Client.recv_reply(client)
             ~> {:ok, "200 OK",
              [
                date: string(),
                "content-length": "85",
                "cache-control": "max-age=0, private, must-revalidate"
              ],
              "%ArgumentError{message: \"upgrade to websocket not supported by Bandit.HTTP1.Adapter\"}"}
    end

    defmodule MyNoopWebSock do
      use NoopWebSock
    end

    def upgrade_websocket(conn) do
      # In actual use, it's the caller's responsibility to ensure the upgrade is valid before
      # calling upgrade_adapter
      conn
      |> upgrade_adapter(:websocket, {MyNoopWebSock, [], []})
    rescue
      e in ArgumentError ->
        conn
        |> send_resp(200, inspect(e))
    end
  end

  describe "response headers" do
    test "writes out a response with a valid date header", context do
      response = Req.get!(context.req, url: "/send_200")

      assert response.status == 200

      date = Bandit.Headers.get_header(response.headers, "date")
      assert TestHelpers.valid_date_header?(date)
    end

    test "returns user-defined date header instead of internal version", context do
      response = Req.get!(context.req, url: "/date_header")

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
    test "writes out a response with deflate encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "34"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == "deflate"

      deflate_context = :zlib.open()
      :ok = :zlib.deflateInit(deflate_context)

      expected =
        deflate_context
        |> :zlib.deflate(String.duplicate("a", 10_000), :sync)
        |> IO.iodata_to_binary()

      assert response.body == expected
    end

    test "writes out a response with gzip encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "46"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == "gzip"
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    test "writes out a response with x-gzip encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "x-gzip"}])

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "46"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == "x-gzip"
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    test "uses the first matching encoding in accept-encoding", context do
      response =
        Req.get!(context.req,
          url: "/send_big_body",
          headers: [{"accept-encoding", "foo, deflate"}]
        )

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "34"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == "deflate"

      deflate_context = :zlib.open()
      :ok = :zlib.deflateInit(deflate_context)

      expected =
        deflate_context
        |> :zlib.deflate(String.duplicate("a", 10_000), :sync)
        |> IO.iodata_to_binary()

      assert response.body == expected
    end

    test "falls back to no encoding if no encodings provided", context do
      response = Req.get!(context.req, url: "/send_big_body")

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "10000"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == nil
      assert response.body == String.duplicate("a", 10_000)
    end

    test "does no encoding if content-encoding header already present in response", context do
      response =
        Req.get!(context.req,
          url: "/send_content_encoding",
          headers: [{"accept-encoding", "deflate"}]
        )

      # Assert that we did not try to compress the body
      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "10000"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == "deflate"
      assert response.body == String.duplicate("a", 10_000)
    end

    test "falls back to no encoding if no encodings match", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "a, b, c"}])

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "10000"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == nil
      assert response.body == String.duplicate("a", 10_000)
    end

    test "falls back to no encoding if compression is disabled", context do
      context =
        http_server(context, http_1_options: [compress: false])
        |> Enum.into(context)

      response =
        Req.get!(context.req,
          url: "/send_big_body",
          base_url: context.base,
          headers: [{"accept-encoding", "deflate"}]
        )

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "10000"
      assert Bandit.Headers.get_header(response.headers, "content-encoding") == nil
      assert response.body == String.duplicate("a", 10_000)
    end

    def send_big_body(conn) do
      conn
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_content_encoding(conn) do
      conn
      |> put_resp_header("content-encoding", "deflate")
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "replaces any incorrect provided content-length headers", context do
      response = Req.get!(context.req, url: "/send_incorrect_content_length")

      assert response.status == 200
      assert Bandit.Headers.get_header(response.headers, "content-length") == "10000"
      assert response.body == String.duplicate("a", 10_000)
    end

    def send_incorrect_content_length(conn) do
      conn
      |> put_resp_header("content-length", "10001")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "writes out a response with no content-length header for 204 responses", context do
      response = Req.get!(context.req, url: "/send_204")

      assert response.status == 204
      assert response.body == ""
      assert is_nil(Bandit.Headers.get_header(response.headers, "content-length"))
    end

    def send_204(conn) do
      send_resp(conn, 204, "")
    end

    test "writes out a response with no content-length header for 304 responses", context do
      response = Req.get!(context.req, url: "/send_304")

      assert response.status == 304
      assert response.body == ""
      assert is_nil(Bandit.Headers.get_header(response.headers, "content-length"))
    end

    def send_304(conn) do
      send_resp(conn, 304, "")
    end

    test "writes out a response with zero content-length for 200 responses", context do
      response = Req.get!(context.req, url: "/send_200")

      assert response.status == 200
      assert response.body == ""
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "writes out a response with zero content-length for 301 responses", context do
      response = Req.get!(context.req, url: "/send_301")

      assert response.status == 301
      assert response.body == ""
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
    end

    def send_301(conn) do
      send_resp(conn, 301, "")
    end

    test "writes out a response with zero content-length for 401 responses", context do
      response = Req.get!(context.req, url: "/send_401")

      assert response.status == 401
      assert response.body == ""
      assert Bandit.Headers.get_header(response.headers, "content-length") == "0"
    end

    def send_401(conn) do
      send_resp(conn, 401, "")
    end

    test "writes out a chunked response", context do
      response = Req.get!(context.req, url: "/send_chunked_200")

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
      response = Req.get!(context.req, url: "/send_full_file")

      assert response.status == 200
      assert response.body == "ABCDEF"
      assert Bandit.Headers.get_header(response.headers, "content-length") == "6"
    end

    def send_full_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "writes out a sent file for parts of a file with content length", context do
      response = Req.get!(context.req, url: "/send_file?offset=1&length=3")

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
      response = Req.get!(context.req, url: "/raise_error")

      assert response.status == 500
    end

    def raise_error(_conn) do
      raise "boom"
    end

    @tag capture_log: true
    test "returns a 500 if the plug does not return anything", context do
      response = Req.get!(context.req, url: "/noop")

      assert response.status == 500
    end

    def noop(conn) do
      conn
    end

    @tag capture_log: true
    test "returns a 500 if the plug does not return a conn", context do
      response = Req.get!(context.req, url: "/return_garbage")

      assert response.status == 500
    end

    def return_garbage(_conn) do
      :nope
    end

    test "silently accepts EXIT messages from normally terminating spwaned processes", context do
      errors =
        capture_log(fn ->
          Req.get!(context.req, url: "/spawn_child")

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
        Req.get!(context.req, url: "/spawn_abnormal_child")

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

  describe "telemetry" do
    test "it should send `start` events for normally completing requests", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :start]]})

      Req.get!(context.req, url: "/send_200")

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :start], %{monotonic_time: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should send `stop` events for normally completing requests", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      # Use a manually built request so we can count exact bytes
      request = "GET /send_200 HTTP/1.1\r\nhost: localhost\r\n\r\n"
      client = SimpleHTTP1Client.tcp_client(context)
      :gen_tcp.send(client, request)
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: 24,
                  req_header_end_time: integer(),
                  req_header_bytes: 19,
                  resp_line_bytes: 17,
                  resp_header_bytes: 110,
                  resp_body_bytes: 0,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should add req metrics to `stop` events for requests with no request body",
         context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      Req.post!(context.req, url: "/do_read_body", body: <<>>)

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: integer(),
                  req_header_end_time: integer(),
                  req_header_bytes: integer(),
                  req_body_start_time: integer(),
                  req_body_end_time: integer(),
                  req_body_bytes: 0,
                  resp_line_bytes: 17,
                  resp_header_bytes: 110,
                  resp_body_bytes: 2,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    def do_read_body(conn) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "OK")
    end

    test "it should add req metrics to `stop` events for requests with request body", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      Req.post!(context.req, url: "/do_read_body", body: String.duplicate("a", 80))

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: integer(),
                  req_header_end_time: integer(),
                  req_header_bytes: integer(),
                  req_body_start_time: integer(),
                  req_body_end_time: integer(),
                  req_body_bytes: 80,
                  resp_line_bytes: 17,
                  resp_header_bytes: 110,
                  resp_body_bytes: 2,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should add req metrics to `stop` events for chunked request body", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      stream = Stream.repeatedly(fn -> "a" end) |> Stream.take(80)
      Req.post!(context.req, url: "/do_read_body", body: {:stream, stream})

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: integer(),
                  req_header_end_time: integer(),
                  req_header_bytes: integer(),
                  req_body_start_time: integer(),
                  req_body_end_time: integer(),
                  req_body_bytes: 80,
                  resp_line_bytes: 17,
                  resp_header_bytes: 110,
                  resp_body_bytes: 2,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should add req metrics to `stop` events for requests with content encoding",
         context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      Req.post!(context.req,
        url: "/do_read_body",
        body: String.duplicate("a", 80),
        compressed: true
      )

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: integer(),
                  req_header_end_time: integer(),
                  req_header_bytes: integer(),
                  req_body_start_time: integer(),
                  req_body_end_time: integer(),
                  req_body_bytes: 80,
                  resp_line_bytes: 17,
                  resp_header_bytes: 135,
                  resp_uncompressed_body_bytes: 2,
                  resp_body_bytes: 22,
                  resp_compression_method: "gzip",
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should add (some) resp metrics to `stop` events for chunked responses", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      Req.get!(context.req, url: "/send_chunked_200")

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: 32,
                  req_header_end_time: integer(),
                  req_header_bytes: 48,
                  resp_line_bytes: 17,
                  resp_header_bytes: 119,
                  resp_body_bytes: 0,
                  resp_start_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    test "it should add resp metrics to `stop` events for sendfile responses", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      Req.get!(context.req, url: "/send_full_file")

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop],
                %{
                  monotonic_time: integer(),
                  duration: integer(),
                  conn: struct_like(Plug.Conn, []),
                  req_line_bytes: 30,
                  req_header_end_time: integer(),
                  req_header_bytes: 48,
                  resp_line_bytes: 17,
                  resp_header_bytes: 110,
                  resp_body_bytes: 6,
                  resp_start_time: integer(),
                  resp_end_time: integer()
                },
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference()
                }}
             ]
    end

    @tag capture_log: true
    test "it should send `stop` events for malformed requests", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      client = SimpleHTTP1Client.tcp_client(context)
      :gen_tcp.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop], %{monotonic_time: integer(), duration: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  error: string()
                }}
             ]
    end

    @tag capture_log: true
    test "it should send `stop` events for timed out requests", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :stop]]})

      client = SimpleHTTP1Client.tcp_client(context)
      :gen_tcp.send(client, "GET / HTTP/1.1\r\nfoo: bar\r\n")
      Process.sleep(1100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :stop], %{monotonic_time: integer(), duration: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  error: :timeout
                }}
             ]
    end

    @tag capture_log: true
    test "it should send `exception` events for erroring requests", context do
      {:ok, collector_pid} =
        start_supervised({Bandit.TelemetryCollector, [[:bandit, :request, :exception]]})

      Req.get!(context.req, url: "/raise_error")

      Process.sleep(100)

      assert Bandit.TelemetryCollector.get_events(collector_pid)
             ~> [
               {[:bandit, :request, :exception], %{monotonic_time: integer()},
                %{
                  connection_telemetry_span_context: reference(),
                  telemetry_span_context: reference(),
                  kind: :exit,
                  exception: %RuntimeError{message: "boom"},
                  stacktrace: list()
                }}
             ]
    end
  end
end
