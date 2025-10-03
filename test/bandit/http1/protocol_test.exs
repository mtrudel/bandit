defmodule HTTP1ProtocolTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  require Logger

  setup :http_server
  setup :req_http1_client

  describe "protocol error logging" do
    @tag :capture_log
    test "errors are short logged by default", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header read HTTP error: \"GARBAGE\\r\\n\""
    end

    @tag :capture_log
    test "errors are verbosely logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (Bandit.HTTPError) Header read HTTP error: \"GARBAGE\\r\\n\""
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    test "errors are not logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: false])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      refute_receive {:log, %{level: :error}}
    end

    test "client closure protocol errors are not logged by default", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      refute_receive {:log, %{level: :error}}
    end

    @tag :capture_log
    test "client closure protocol errors are short logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    @tag :capture_log
    test "client closure protocol errors are verbosely logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (Bandit.TransportError) Unrecoverable error: closed"
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    @tag :capture_log
    test "it provides minimal metadata when short logging", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, log_event}, 500

      assert %{
               meta: %{
                 domain: [:elixir, :bandit],
                 crash_reason:
                   {%Bandit.HTTPError{message: "Header read HTTP error: \"GARBAGE\\r\\n\""}, []},
                 plug: {__MODULE__, []}
               }
             } = log_event
    end

    @tag :capture_log
    test "it provides full metadata when verbose logging", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error} = log_event}, 500

      assert %{
               meta: %{
                 domain: [:elixir, :bandit],
                 crash_reason:
                   {%Bandit.HTTPError{message: "Header read HTTP error: \"GARBAGE\\r\\n\""},
                    [_ | _] = _stacktrace},
                 plug: {__MODULE__, []}
               }
             } = log_event
    end
  end

  describe "invalid requests" do
    @tag :capture_log
    test "returns a 400 if the request cannot be parsed", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header read HTTP error: \"GARBAGE\\r\\n\""
    end

    @tag :capture_log
    test "returns a 400 if the request has an invalid http version", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: localhost"], "0.9")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Invalid HTTP version: {0, 9}"
    end
  end

  describe "keepalive requests" do
    test "handles pipeline requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        String.duplicate("GET /send_ok HTTP/1.1\r\nHost: localhost\r\n\r\n", 50)
      )

      for _ <- 1..50 do
        # Need to read the exact size of the expected response because SimpleHTTP1Client
        # doesn't track 'rest' bytes and ends up throwing a bunch of responses on the floor
        {:ok, bytes} = Transport.recv(client, 152)
        assert({:ok, "200 OK", _, _} = SimpleHTTP1Client.parse_response(client, bytes))
      end
    end

    test "handles pipeline requests with unread POST bodies", context do
      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        String.duplicate(
          "POST /send_ok HTTP/1.1\r\nHost: localhost\r\nContent-Length:3\r\n\r\nABC",
          50
        )
      )

      for _ <- 1..50 do
        # Need to read the exact size of the expected response because SimpleHTTP1Client
        # doesn't track 'rest' bytes and ends up throwing a bunch of responses on the floor
        {:ok, bytes} = Transport.recv(client, 152)
        assert({:ok, "200 OK", _, _} = SimpleHTTP1Client.parse_response(client, bytes))
      end
    end

    def send_ok(conn) do
      send_resp(conn, 200, "OK")
    end

    test "closes connection after max_requests is reached", context do
      context =
        context
        |> http_server(http_1_options: [max_requests: 3])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    test "closes connection after exception is raised (for safety)", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/known_crasher", ["host: banana"])

      assert {:ok, "418 I'm a teapot", [connection: "close"], _} =
               SimpleHTTP1Client.recv_reply(client)

      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def known_crasher(_conn) do
      raise SafeError, "boom"
    end

    test "idle keepalive connections are closed after read_timeout", context do
      context =
        context
        |> http_server(thousand_island_options: [read_timeout: 100])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: localhost"])
      assert {:ok, "200 OK", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
      Process.sleep(110)

      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    test "responses which contain a connection: close header close the connection", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/close_connection", ["host: localhost"])

      assert {:ok, "200 OK", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def close_connection(conn) do
      conn
      |> put_resp_header("connection", "close")
      |> send_resp(200, "OK")
    end

    test "keepalive mixed-case header connections are respected in HTTP/1.0", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/echo_components",
        ["host: localhost", "connection: Keep-Alive"],
        "1.0"
      )

      assert {:ok, "200 OK", _headers, _body} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/echo_components",
        ["host: localhost", "connection: Keep-Alive"],
        "1.0"
      )

      assert {:ok, "200 OK", _headers, _body} = SimpleHTTP1Client.recv_reply(client)
    end

    test "keepalive are explicitly signalled in HTTP/1.0", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/echo_components",
        ["host: localhost", "connection: keep-alive"],
        "1.0"
      )

      assert {:ok, "200 OK", headers, _body} = SimpleHTTP1Client.recv_reply(client)
      assert [{:connection, "keep-alive"} | _headers] = headers
    end

    test "unread content length bodies are read before starting a new request", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/echo_method", [
        "host: localhost",
        "content-length: 6"
      ])

      Transport.send(client, "ABCDEF")
      assert {:ok, "200 OK", _headers, "POST"} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_method", ["host: banana"])
      assert {:ok, "200 OK", _headers, "GET"} = SimpleHTTP1Client.recv_reply(client)
    end

    test "unread chunked bodies are read before starting a new request", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/echo_method", [
        "host: localhost",
        "transfer-encoding: chunked"
      ])

      Transport.send(client, "6\r\nABCDEF\r\n0\r\n\r\n")
      assert {:ok, "200 OK", _headers, "POST"} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/echo_method", ["host: banana"])
      assert {:ok, "200 OK", _headers, "GET"} = SimpleHTTP1Client.recv_reply(client)
    end

    def echo_method(conn) do
      send_resp(conn, 200, conn.method)
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

    @tag :capture_log
    test "returns 400 if no host header set in HTTP/1.1", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components")
      assert {:ok, "400 Bad Request", _headers, _body} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Unable to obtain host and port: No host header"
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

    @tag :capture_log
    test "returns 400 if port cannot be parsed from host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana:-1234"])
      assert {:ok, "400 Bad Request", _headers, _body} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header contains invalid port"
    end

    test "derives port from schema default if no port specified in host header", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == 80
    end

    test "derives port from schema default if no host header set in HTTP/1.0", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/echo_components", [], "1.0")
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == 80
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

    @tag :capture_log
    test "returns 400 if a non-absolute path is send", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "./../non_absolute_path", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Unsupported request target (RFC9112§3.2)"
    end

    @tag :capture_log
    test "returns 400 if path has no leading slash", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "path_without_leading_slash", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Unsupported request target (RFC9112§3.2)"
    end
  end

  describe "absolute-form request target (RFC9112§3.2.2)" do
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

    test "derives port from schema default if no port specified in the URI", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "http://banana/echo_components", ["host: banana"])
      assert {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      assert Jason.decode!(body)["port"] == 80
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
    @tag :capture_log
    test "returns 400 for authority-form / CONNECT requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "CONNECT", "www.example.com:80", ["host: localhost"])
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) schemeURI is not supported"
    end
  end

  describe "asterisk-form request target (RFC9112§3.2.4)" do
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
    @tag :capture_log
    test "returns 414 for request lines that are too long", context do
      context =
        context
        |> http_server(http_1_options: [max_request_line_length: 5000])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", String.duplicate("a", 5000 - 14))

      assert {:ok, "414 Request-URI Too Long", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Request URI is too long"
    end
  end

  describe "request headers" do
    test "reads headers properly", context do
      response =
        Req.get!(context.req,
          url: "/expect_headers/a//b/c?abc=def",
          headers: [{"x-fruit", "banana"}, {"x-fruit", "mango"}]
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
      assert Plug.Conn.get_req_header(conn, "x-fruit") == ["banana", "mango"]

      # Ensure header order is correct
      assert conn.req_headers
             ~> [
               {"host", string(starts_with: "localhost:")},
               {"user-agent", string(starts_with: "mint/")},
               {"x-fruit", "banana"},
               {"x-fruit", "mango"}
             ]

      # make iodata explicit
      send_resp(conn, 200, ["O", "K"])
    end

    @tag :capture_log
    test "returns 431 for header lines that are too long", context do
      context =
        context
        |> http_server(http_1_options: [max_header_length: 5000])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", [
        "host: localhost",
        "foo: " <> String.duplicate("a", 5000 - 6)
      ])

      assert {:ok, "431 Request Header Fields Too Large", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header too long"
    end

    @tag :capture_log
    test "returns 431 for too many header lines", context do
      context =
        context
        |> http_server(http_1_options: [max_header_count: 40])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      headers = for i <- 1..40, do: "header#{i}: foo"

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/echo_components",
        headers ++ ["host: localhost"]
      )

      assert {:ok, "431 Request Header Fields Too Large", _headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Too many headers"
    end
  end

  describe "content-length request bodies" do
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

    # Error case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    @tag :capture_log
    test "rejects a request with non-matching multiple content lengths", context do
      # Use a smaller body size to avoid raciness in reading the response
      response =
        Req.post!(context.req,
          url: "/expect_body_with_multiple_content_length",
          headers: [{"content-length", "8000,8001,8000"}],
          body: String.duplicate("a", 8_000)
        )

      assert response.status == 400

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) Content length unknown error: \"invalid content-length header (RFC9112§6.3.5)\""
    end

    @tag :capture_log
    test "rejects a request with negative content-length", context do
      response =
        Req.post!(context.req,
          url: "/negative_content_length",
          headers: [{"content-length", "-321"}],
          body: String.duplicate("a", 1_000)
        )

      assert response.status == 400

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) Content length unknown error: \"invalid content-length header (RFC9112§6.3.5)\""
    end

    @tag :capture_log
    test "rejects a request with non-integer content length", context do
      response =
        Req.post!(context.req,
          url: "/expect_body_with_multiple_content_length",
          headers: [{"content-length", "foo"}],
          body: String.duplicate("a", 8_000)
        )

      assert response.status == 400

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) Content length unknown error: \"invalid content-length header (RFC9112§6.3.5)\""
    end

    test "handles the case where we ask for less than is already in the buffer", context do
      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        "POST /in_buffer_read HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nABCDE"
      )

      assert {:ok, "200 OK", _, "A,BCDE"} = SimpleHTTP1Client.recv_reply(client)
    end

    def in_buffer_read(conn) do
      {:more, first, conn} = Plug.Conn.read_body(conn, length: 1)
      {:ok, second, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "#{first},#{second}")
    end

    test "handles the case where we ask for more than is already in the buffer", context do
      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        "POST /beyond_buffer_read HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nAB"
      )

      Process.sleep(10)
      Transport.send(client, "CDE")

      assert {:ok, "200 OK", _, "ABC,D,E"} = SimpleHTTP1Client.recv_reply(client)
    end

    def beyond_buffer_read(conn) do
      {:more, first, conn} = Plug.Conn.read_body(conn, length: 3)
      {:more, second, conn} = Plug.Conn.read_body(conn, length: 1)
      {:ok, third, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "#{first},#{second},#{third}")
    end

    test "handles the case where we read from the network in smaller chunks than we return",
         context do
      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        "POST /read_one_byte_at_a_time HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\n"
      )

      Process.sleep(10)
      Transport.send(client, "ABCDE")

      assert {:ok, "200 OK", _, "ABCDE"} = SimpleHTTP1Client.recv_reply(client)
    end

    def read_one_byte_at_a_time(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 5, read_length: 1)
      send_resp(conn, 200, body)
    end

    @tag :capture_log
    test "handles the case where the declared content length is longer than what is sent",
         context do
      context =
        context
        |> http_server(thousand_island_options: [read_timeout: 100])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(
        client,
        "POST /short_body HTTP/1.1\r\nhost: localhost\r\ncontent-length: 5\r\n\r\nABC"
      )

      assert {:ok, "408 Request Timeout", _, ""} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Body read timeout"
    end

    def short_body(conn) do
      Plug.Conn.read_body(conn)
      raise "Shouldn't get here"
    end
  end

  describe "chunked request bodies" do
    test "reads a chunked body properly", context do
      stream =
        Stream.repeatedly(fn -> String.duplicate("0123456789", 100_000) end)
        |> Stream.take(8)

      response = Req.post!(context.req, url: "/expect_chunked_body", body: stream)

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_chunked_body(conn) do
      assert Plug.Conn.get_req_header(conn, "transfer-encoding") == ["chunked"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("0123456789", 800_000)
      send_resp(conn, 200, "OK")
    end
  end

  describe "upgrade handling" do
    @tag :capture_log
    test "returns a 400 and errors loudly in cases where an upgrade is indicated but the connection is not a GET",
         context do
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

      assert SimpleHTTP1Client.recv_reply(client) ~> {:ok, "400 Bad Request", list(), ""}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) HTTP method POST unsupported"
    end

    @tag :capture_log
    test "returns a 400 and errors loudly in cases where an upgrade is indicated but upgrade header is incorrect",
         context do
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

      assert SimpleHTTP1Client.recv_reply(client) ~> {:ok, "400 Bad Request", list(), ""}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) 'upgrade' header must contain 'websocket', got [\"NOPE\"]"
    end

    @tag :capture_log
    test "returns a 400 and errors loudly in cases where an upgrade is indicated but connection header is incorrect",
         context do
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

      assert SimpleHTTP1Client.recv_reply(client) ~> {:ok, "400 Bad Request", list(), ""}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) 'connection' header must contain 'upgrade', got [\"NOPE\"]"
    end

    @tag :capture_log
    test "returns a 400 and errors loudly in cases where an upgrade is indicated but key header is incorrect",
         context do
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

      assert SimpleHTTP1Client.recv_reply(client) ~> {:ok, "400 Bad Request", list(), ""}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) 'sec-websocket-key' header is absent"
    end

    @tag :capture_log
    test "returns a 400 and errors loudly in cases where an upgrade is indicated but version header is incorrect",
         context do
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

      assert SimpleHTTP1Client.recv_reply(client) ~> {:ok, "400 Bad Request", list(), ""}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTPError) 'sec-websocket-version' header must equal '13', got [\"99\"]"
    end

    test "returns a 400 and errors loudly if websocket support is not enabled", context do
      context =
        context
        |> http_server(websocket_options: [enabled: false])
        |> Enum.into(context)

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
                "content-length": "79",
                vary: "accept-encoding",
                "cache-control": "max-age=0, private, must-revalidate"
              ],
              "%ArgumentError{message: \"upgrade to websocket not supported by Bandit.Adapter\"}"}
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

  describe "response body" do
    test "writes out a response with deflate encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["34"]
      assert response.headers["content-encoding"] == ["deflate"]
      assert response.headers["vary"] == ["accept-encoding"]

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, response.body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "writes out a response with gzip encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["46"]
      assert response.headers["content-encoding"] == ["gzip"]
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    test "writes out a response with x-gzip encoding if so negotiated", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "x-gzip"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["46"]
      assert response.headers["content-encoding"] == ["x-gzip"]
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    # TODO Remove conditional once Erlang v28 is required
    if Code.ensure_loaded?(:zstd) do
      test "writes out a response with zstd encoding if so negotiated", context do
        response =
          Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "zstd"}])

        assert response.status == 200
        assert response.headers["content-length"] == ["19"]
        assert response.headers["content-encoding"] == ["zstd"]
        assert response.headers["vary"] == ["accept-encoding"]

        assert response.body ==
                 :erlang.iolist_to_binary(:zstd.compress(String.duplicate("a", 10_000)))
      end
    end

    test "uses the first matching encoding in accept-encoding", context do
      response =
        Req.get!(context.req,
          url: "/send_big_body",
          headers: [{"accept-encoding", "foo, deflate"}]
        )

      assert response.status == 200
      assert response.headers["content-length"] == ["34"]
      assert response.headers["content-encoding"] == ["deflate"]
      assert response.headers["vary"] == ["accept-encoding"]

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, response.body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "does not indicate content encoding or vary for 204 responses", context do
      response =
        Req.get!(context.req, url: "/send_204", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 204
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == nil
      assert response.body == ""
    end

    test "does not indicate content encoding but indicates vary for 304 responses", context do
      response =
        Req.get!(context.req, url: "/send_304", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 304
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == ""
    end

    test "does not indicate content encoding but indicates vary for zero byte responses",
         context do
      response =
        Req.get!(context.req, url: "/send_empty", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 200
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == ""
    end

    def send_empty(conn) do
      conn
      |> send_resp(200, "")
    end

    test "writes out an encoded response for an iolist body", context do
      response =
        Req.get!(context.req, url: "/send_iolist_body", headers: [{"accept-encoding", "deflate"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["34"]
      assert response.headers["content-encoding"] == ["deflate"]
      assert response.headers["vary"] == ["accept-encoding"]

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, response.body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "deflate encodes chunk responses", context do
      response =
        Req.get!(context.req,
          url: "/send_big_body_chunked",
          headers: [{"accept-encoding", "deflate"}]
        )

      assert response.status == 200
      assert response.headers["content-encoding"] == ["deflate"]
      assert response.headers["vary"] == ["accept-encoding"]

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, response.body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "does not gzip encode chunk responses", context do
      response =
        Req.get!(context.req,
          url: "/send_big_body_chunked",
          headers: [{"accept-encoding", "gzip"}]
        )

      assert response.status == 200
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "falls back to no encoding if no encodings provided", context do
      response = Req.get!(context.req, url: "/send_big_body")

      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
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
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == ["deflate"]
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "does no encoding if a strong etag is present in the response", context do
      response =
        Req.get!(context.req,
          url: "/send_strong_etag",
          headers: [{"accept-encoding", "deflate"}]
        )

      # Assert that we did not try to compress the body
      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "does content encoding if a weak etag is present in the response", context do
      response =
        Req.get!(context.req, url: "/send_weak_etag", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["46"]
      assert response.headers["content-encoding"] == ["gzip"]
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    test "does no encoding if cache-control: no-transform is present in the response", context do
      response =
        Req.get!(context.req,
          url: "/send_no_transform",
          headers: [{"accept-encoding", "deflate"}]
        )

      # Assert that we did not try to compress the body
      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "falls back to no encoding if no encodings match", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "a, b, c"}])

      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "falls back to no encoding if compression is disabled", context do
      context =
        context
        |> http_server(http_options: [compress: false])
        |> Enum.into(context)

      response =
        Req.get!(context.req,
          url: "/send_big_body",
          base_url: context.base,
          headers: [{"accept-encoding", "deflate"}]
        )

      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-encoding"] == nil
      assert response.headers["vary"] == nil
      assert response.body == String.duplicate("a", 10_000)
    end

    def send_big_body(conn) do
      conn
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_big_body_chunked(conn) do
      conn = send_chunked(conn, 200)

      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))
      {:ok, conn} = chunk(conn, String.duplicate("a", 1_000))

      conn
    end

    def send_iolist_body(conn) do
      conn
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, List.duplicate("a", 10_000))
    end

    def send_content_encoding(conn) do
      conn
      |> put_resp_header("content-encoding", "deflate")
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_strong_etag(conn) do
      conn
      |> put_resp_header("etag", "\"1234\"")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_weak_etag(conn) do
      conn
      |> put_resp_header("etag", "W/\"1234\"")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_no_transform(conn) do
      conn
      |> put_resp_header("cache-control", "no-transform")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "sends expected content-length but no body for HEAD requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/send_big_body", ["host: localhost"])

      assert {:ok, "200 OK", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "10000"
    end

    test "respects provided content-length headers for HEAD responses", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/head_preserve_content_length", ["host: localhost"])

      assert {:ok, "200 OK", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "10001"
    end

    def head_preserve_content_length(conn) do
      conn
      |> put_resp_header("content-length", "10001")
      |> send_resp(200, "")
    end

    test "replaces any incorrect provided content-length headers", context do
      response = Req.get!(context.req, url: "/send_incorrect_content_length")

      assert response.status == 200
      assert response.headers["content-length"] == ["10000"]
      assert response.body == String.duplicate("a", 10_000)
    end

    test "replaces any incorrect provided content-length headers for HEAD responses", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "HEAD", "/send_incorrect_content_length", ["host: localhost"])

      assert {:ok, "200 OK", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "10000"
    end

    def send_incorrect_content_length(conn) do
      conn
      |> put_resp_header("content-length", "10001")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "writes out a response with no content-length header or body for 204 responses",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/send_204", ["host: localhost"])

      assert {:ok, "204 No Content", headers, ""} = SimpleHTTP1Client.recv_reply(client)
      assert Bandit.Headers.get_header(headers, :"content-length") == nil
    end

    def send_204(conn) do
      send_resp(conn, 204, "this is an invalid body")
    end

    test "writes out a response with content-length header but no body for 304 responses",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/send_304", ["host: localhost"])

      assert {:ok, "304 Not Modified", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "5"
    end

    def send_304(conn) do
      send_resp(conn, 304, "abcde")
    end

    test "respects plug-provided zero content-length and no body for 304 responses", context do
      response = Req.head!(context.req, url: "/send_304_zero_content_length")

      assert response.status == 304
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
    end

    def send_304_zero_content_length(conn) do
      conn
      |> put_resp_header("content-length", "0")
      |> send_resp(304, "")
    end

    test "respects plug-provided nonzero content-length but no body for 304 responses", context do
      response = Req.head!(context.req, url: "/send_304_nonzero_content_length")

      assert response.status == 304
      assert response.body == ""
      assert response.headers["content-length"] == ["5"]
    end

    def send_304_nonzero_content_length(conn) do
      conn
      |> put_resp_header("content-length", "5")
      |> send_resp(304, "abcde")
    end

    test "writes out a response with zero content-length for 200 responses", context do
      response = Req.get!(context.req, url: "/send_200")

      assert response.status == 200
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
    end

    test "writes out a response omitting content-length for HEAD 200 responses", context do
      response = Req.head!(context.req, url: "/send_200")

      assert response.status == 200
      assert response.body == ""
      assert response.headers["content-length"] == nil
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "respects plug-provided zero content-length and no body for HEAD 200 responses",
         context do
      response = Req.head!(context.req, url: "/send_200_zero_content_length")

      assert response.status == 200
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
    end

    def send_200_zero_content_length(conn) do
      conn
      |> put_resp_header("content-length", "0")
      |> send_resp(200, "")
    end

    test "respects plug-provided nonzero content-length but no body for HEAD 200 responses",
         context do
      response = Req.head!(context.req, url: "/send_200_nonzero_content_length")

      assert response.status == 200
      assert response.body == ""
      assert response.headers["content-length"] == ["5"]
    end

    def send_200_nonzero_content_length(conn) do
      conn
      |> put_resp_header("content-length", "5")
      |> send_resp(200, "abcde")
    end

    test "writes out a response with zero content-length for 301 responses", context do
      response = Req.get!(context.req, url: "/send_301")

      assert response.status == 301
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
    end

    def send_301(conn) do
      send_resp(conn, 301, "")
    end

    test "writes out a response with zero content-length for 401 responses", context do
      response = Req.get!(context.req, url: "/send_401")

      assert response.status == 401
      assert response.body == ""
      assert response.headers["content-length"] == ["0"]
    end

    def send_401(conn) do
      send_resp(conn, 401, "")
    end

    test "writes out a chunked response", context do
      response = Req.get!(context.req, url: "/send_chunked_200")

      assert response.status == 200
      assert response.body == "OK"
      assert response.headers["transfer-encoding"] == ["chunked"]
    end

    def send_chunked_200(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk("OK")

      conn
    end

    test "streams a content-length delimited response if content-length is set before chunking",
         context do
      response = Req.get!(context.req, url: "/send_chunked_200_with_content_length")

      assert response.status == 200
      assert response.body == "OK"
      assert response.headers["transfer-encoding"] != ["chunked"]
      assert response.headers["content-length"] == ["2"]
    end

    def send_chunked_200_with_content_length(conn) do
      conn =
        conn
        |> put_resp_header("content-length", "2")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, "O")
      {:ok, conn} = chunk(conn, "K")

      conn
    end

    test "does not add the transfer-encoding header for 204 responses", context do
      response = Req.get!(context.req, url: "/send_chunked_204")

      assert response.status == 204
      assert response.body == ""
      refute Map.has_key?(response.headers, "transfer-encoding")
    end

    def send_chunked_204(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(204)
        |> chunk("")

      conn
    end

    test "does not write out transfer-encoding headers or body for a chunked response to a HEAD request",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/send_chunked_200", ["host: localhost"])

      assert {:ok, "200 OK", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)

      refute Bandit.Headers.get_header(headers, :"content-length")
      refute Bandit.Headers.get_header(headers, :"transfer-encoding")
    end

    test "writes out a chunked iolist response", context do
      response = Req.get!(context.req, url: "/send_chunked_200_iolist")

      assert response.status == 200
      assert response.body == "OK"
      assert response.headers["transfer-encoding"] == ["chunked"]
    end

    def send_chunked_200_iolist(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk(["OK"])

      conn
    end

    test "writes out a sent file for the entire file with content length", context do
      response = Req.get!(context.req, url: "/send_full_file")

      assert response.status == 200
      assert response.body == "ABCDEF"
      assert response.headers["content-length"] == ["6"]
    end

    test "writes out headers but not body for files requested via HEAD request", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/send_full_file", ["host: localhost"])

      assert {:ok, "200 OK", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "6"
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def send_full_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "does not write out a content-length header or body for files on a 204",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/send_full_file_204", ["host: localhost"])

      assert {:ok, "204 No Content", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == nil
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def send_full_file_204(conn) do
      conn
      |> send_file(204, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "write out a content-length header but no body for files on a 304", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "HEAD", "/send_full_file_304", ["host: localhost"])

      assert {:ok, "304 Not Modified", headers, ""} = SimpleHTTP1Client.recv_reply(client, true)
      assert Bandit.Headers.get_header(headers, :"content-length") == "6"
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    def send_full_file_304(conn) do
      conn
      |> send_file(304, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "writes out a sent file for parts of a file with content length", context do
      response = Req.get!(context.req, url: "/send_file?offset=1&length=3")

      assert response.status == 200
      assert response.body == "BCD"
      assert response.headers["content-length"] == ["3"]
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

  test "sending informational responses", context do
    client = SimpleHTTP1Client.tcp_client(context)
    SimpleHTTP1Client.send(client, "GET", "/send_inform", ["host: localhost"])

    Process.sleep(10)
    assert {:ok, "100 Continue", headers, rest} = SimpleHTTP1Client.recv_reply(client)
    assert Bandit.Headers.get_header(headers, :"x-from") == "inform"
    assert {:ok, "200 OK", _headers, "Informer"} = SimpleHTTP1Client.parse_response(client, rest)
  end

  test "does not send informational responses to HTTP/1.0 clients", context do
    client = SimpleHTTP1Client.tcp_client(context)
    SimpleHTTP1Client.send(client, "GET", "/send_inform", ["host: localhost"], "1.0")

    assert {:ok, "200 OK", _headers, "Informer"} = SimpleHTTP1Client.recv_reply(client)
  end

  def send_inform(conn) do
    conn = conn |> inform(100, [{:"x-from", "inform"}])
    conn |> send_resp(200, "Informer")
  end

  describe "connection closure / error handling" do
    @tag :capture_log
    test "raises an error if client closes while headers are being read", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      Transport.send(client, "GET / HTTP/1.1\r\nHost: localhost\r\nFoo: ")
      Process.sleep(10)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    @tag :capture_log
    test "raises an error if client closes while body is being read", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/expect_incomplete_body", [
        "host: localhost",
        "content-length: 6"
      ])

      Transport.send(client, "ABC")
      Process.sleep(10)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    def expect_incomplete_body(conn) do
      {:ok, _body, _conn} = Plug.Conn.read_body(conn)
      Logger.error("IMPOSSIBLE")
    end

    @tag :capture_log
    test "raises an error if client closes while body is being written", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(10)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    def sleep_and_send(conn) do
      Process.sleep(100)

      conn = send_resp(conn, 200, "IMPOSSIBLE")

      Logger.error("IMPOSSIBLE")
      conn
    end

    test "returns an error if client closes while chunked body is being written", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send_chunked", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)
    end

    def sleep_and_send_chunked(conn) do
      conn = send_chunked(conn, 200)
      Process.sleep(100)
      assert chunk(conn, "IMPOSSIBLE") == {:error, :closed}
      conn
    end

    @tag :capture_log
    test "raises an error if client closes before sendfile body is being written", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/sleep_and_sendfile", ["host: localhost"])
      Process.sleep(10)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    def sleep_and_sendfile(conn) do
      Process.sleep(100)
      conn = send_file(conn, 204, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
      Logger.error("IMPOSSIBLE")
      conn
    end

    test "silently exits if client closes during keepalive", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: localhost"])
      SimpleHTTP1Client.recv_reply(client)
      Transport.close(client)

      refute_receive {:log, _}
    end

    def hello_world(conn) do
      send_resp(conn, 200, "OK module")
    end
  end
end
