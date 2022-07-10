defmodule WebSocketHTTP1HandshakeTest do
  use WebSocketServerHelpers

  setup :http1_websocket_server

  describe "HTTP/1.1 handshake" do
    test "accepts well formed requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 101 Switching Protocols\r
             content-length: 0\r
             cache-control: max-age=0, private, must-revalidate\r
             upgrade: websocket\r
             connection: Upgrade\r
             sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
             \r
             """
    end

    test "does not accept non-GET requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      POST /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      # Assert that we receive an HTTP response from Plug (ie: we do not upgrade)
      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept non-HTTP/1.1 requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.0\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      # Assert that we receive an HTTP response from Plug (ie: we do not upgrade)
      assert response == """
             HTTP/1.0 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept requests without a host header", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept non-websocket upgrade requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: bogus\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept non-upgrade requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: close\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept requests without a request key", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: bogus\r
      Connection: Upgrade\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end

    test "does not accept requests without a version of 13", context do
      client = SimpleWebSocketClient.tcp_client(context)

      :gen_tcp.send(client, """
      GET /websocket_test HTTP/1.1\r
      Host: server.example.com\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 12\r
      \r
      """)

      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == """
             HTTP/1.1 204 No Content\r
             cache-control: max-age=0, private, must-revalidate\r
             \r
             """
    end
  end

  def websocket_test(conn) do
    Plug.Conn.send_resp(conn, 204, <<>>)
  end
end
