defmodule UpgradeValidationTest do
  # Note that these tests do not actually upgrade the connection to a WebSocket; they're just a
  # plug that happens to call `validate_upgrade/1` and returns the result. The fact that we use
  # HTTP calls to do this is to avoid having to manually construct `Plug.Conn` structs for testing

  use ExUnit.Case, async: true
  use ServerHelpers

  setup :http_server

  def validate_upgrade(conn) do
    case Bandit.WebSocket.UpgradeValidation.validate_upgrade(conn) do
      :ok -> Plug.Conn.send_resp(conn, 200, "ok")
      {:error, reason} -> Plug.Conn.send_resp(conn, 200, reason)
    end
  end

  describe "HTTP/1 upgrades" do
    test "accepts well formed requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "200 OK", _headers, "ok"} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-GET requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "200 OK", _headers, "HTTP method POST unsupported"} =
               SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-HTTP/1.1 requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/validate_upgrade",
        [
          "Host: server.example.com",
          "Upgrade: WeBsOcKeT",
          "Connection: UpGrAdE",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13"
        ],
        "1.0"
      )

      assert {:ok, "200 OK", _headers, "HTTP version HTTP/1.0 unsupported"} =
               SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-upgrade requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: close",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "200 OK", _headers,
              "'connection' header must contain 'upgrade', got [\"close\"]"} =
               SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-websocket upgrade requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: bogus",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "200 OK", _headers,
              "'upgrade' header must contain 'websocket', got [\"bogus\"]"} =
               SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept requests without a request key", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "200 OK", _headers, "'sec-websocket-key' header is absent"} =
               SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept requests without a version of 13", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/validate_upgrade", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 12"
      ])

      assert {:ok, "200 OK", _headers,
              "'sec-websocket-version' header must equal '13', got [\"12\"]"} =
               SimpleHTTP1Client.recv_reply(client)
    end
  end
end
