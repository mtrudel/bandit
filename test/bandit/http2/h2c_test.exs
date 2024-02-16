defmodule H2CTest do
  use ExUnit.Case, async: false
  use ServerHelpers

  import ExUnit.CaptureLog

  def echo_protocol(conn) do
    conn
    |> send_resp(200, to_string(get_http_protocol(conn)))
  end

  def echo_components(conn) do
    send_resp(
      conn,
      200,
      conn |> Map.take([:scheme, :host, :port, :path_info, :query_string]) |> Jason.encode!()
    )
  end

  def echo_body(conn) do
    {:ok, body, conn} = read_body(conn)
    send_resp(conn, 200, body)
  end

  describe "h2c handling over TCP" do
    setup :http_server

    test "upgrade to HTTP/2 over TCP using h2c header", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_protocol", [
        "Connection: Upgrade, HTTP2-Settings",
        "Host: banana",
        "Upgrade: h2c",
        "HTTP2-Settings: "
      ])

      {:ok, upgrade_response} = Transport.recv(client, 131)

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.parse_response(client, upgrade_response)

      assert Enum.any?(headers, fn {key, value} -> key == :connection && value == "Upgrade" end)
      assert Enum.any?(headers, fn {key, value} -> key == :upgrade && value == "h2c" end)

      assert {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>} = Transport.recv(client, 9)

      Transport.send(client, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)

      assert {:ok, 1, false, _headers, recv_ctx} = SimpleH2Client.recv_headers(client)
      assert SimpleH2Client.recv_body(client) == {:ok, 1, true, "HTTP/2"}

      {:ok, _send_ctx} =
        SimpleH2Client.send_simple_headers(client, 3, :get, "/echo_components", context.port)

      assert {:ok, 3, false, _headers, _recv_ctx} = SimpleH2Client.recv_headers(client, recv_ctx)
      {:ok, 3, true, body} = SimpleH2Client.recv_body(client)

      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "initial upgrade request body is handled", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_body", [
        "Connection: Upgrade, HTTP2-Settings",
        "Host: banana",
        "Upgrade: h2c",
        "HTTP2-Settings: ",
        "Content-Length: 8"
      ])

      Transport.send(client, "req_body")

      {:ok, upgrade_response} = Transport.recv(client, 131)

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.parse_response(client, upgrade_response)

      assert Enum.any?(headers, fn {key, value} -> key == :connection && value == "Upgrade" end)
      assert Enum.any?(headers, fn {key, value} -> key == :upgrade && value == "h2c" end)

      assert {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>} = Transport.recv(client, 9)

      Transport.send(client, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)

      assert {:ok, 1, false, _headers, _recv_ctx} = SimpleH2Client.recv_headers(client)
      assert SimpleH2Client.recv_body(client) == {:ok, 1, true, "req_body"}
    end

    test "fails when initial upgrade request body too large", context do
      client = SimpleHTTP1Client.tcp_client(context)

      errors =
        capture_log(fn ->
          SimpleHTTP1Client.send(client, "GET", "/echo_body", [
            "Connection: Upgrade, HTTP2-Settings",
            "Host: banana",
            "Upgrade: h2c",
            "HTTP2-Settings: ",
            "Content-Length: 9000000"
          ])

          Transport.send(client, String.duplicate("a", 9_000_000))
          Process.sleep(100)
        end)

      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert errors =~ "body_too_large"
    end

    test "fails with invalid url_base64 value in HTTP2-Settings header", context do
      client = SimpleHTTP1Client.tcp_client(context)

      errors =
        capture_log(fn ->
          SimpleHTTP1Client.send(client, "GET", "/echo_protocol", [
            "Connection: Upgrade, HTTP2-Settings",
            "Host: banana",
            "Upgrade: h2c",
            "HTTP2-Settings: mumbojumbo!"
          ])

          Process.sleep(100)
        end)

      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert errors =~ "Invalid http2-settings value (RFC7540§3.2.1)"
    end

    test "fails with invalid settings in HTTP2-Settings header", context do
      client = SimpleHTTP1Client.tcp_client(context)

      errors =
        capture_log(fn ->
          SimpleHTTP1Client.send(client, "GET", "/echo_protocol", [
            "Connection: Upgrade, HTTP2-Settings",
            "Host: banana",
            "Upgrade: h2c",
            "HTTP2-Settings: YWxpd2FzaGVyZQ"
          ])

          Process.sleep(100)
        end)

      {:ok, upgrade_response} = Transport.recv(client, 0)

      assert {:ok, "400 Bad Request", _headers, <<>>} =
               SimpleHTTP1Client.parse_response(client, upgrade_response)

      assert errors =~ "Invalid http2-settings value (RFC7540§3.2.1)"
    end
  end

  test "rejects h2c over TLS", context do
    context = https_server(context)
    client = Transport.tls_client(context, ["http/1.1"])

    errors =
      capture_log(fn ->
        SimpleHTTP1Client.send(client, "GET", "/echo_protocol", [
          "Connection: Upgrade, HTTP2-Settings",
          "Host: banana",
          "Upgrade: h2c",
          "HTTP2-Settings: "
        ])

        Process.sleep(100)
      end)

    assert {:ok, "400 Bad Request", _, <<>>} = SimpleHTTP1Client.recv_reply(client)
    assert errors =~ "h2c must use http (RFC7540§3.2)"
  end

  test "ignores h2c when http2 is disabled", context do
    context = http_server(context, http_2_options: [enabled: false])

    client = SimpleHTTP1Client.tcp_client(context)

    SimpleHTTP1Client.send(client, "GET", "/echo_protocol", [
      "Connection: Upgrade, HTTP2-Settings",
      "Host: banana",
      "Upgrade: h2c",
      "HTTP2-Settings: "
    ])

    assert {:ok, "200 OK", _, "HTTP/1.1"} = SimpleHTTP1Client.recv_reply(client)
  end
end
