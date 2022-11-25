defmodule WebSocketHTTP1HandshakeTest do
  # This is fundamentally a test of the Plug helpers in Bandit.WebSocket.Handshake, so we define
  # a simple Plug that uses these handshakes to upgrade to a no-op WebSock implementation

  use ExUnit.Case, async: true
  use ServerHelpers

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  setup :http_server

  defmodule MyNoopWebSock do
    use NoopWebSock
  end

  def call(conn, _opts) do
    case Bandit.WebSocket.Handshake.valid_upgrade?(conn) do
      true ->
        opts = if List.first(conn.path_info) == "compress", do: [compress: true], else: []

        conn
        |> Plug.Conn.upgrade_adapter(:websocket, {MyNoopWebSock, [], opts})

      false ->
        conn
        |> Plug.Conn.send_resp(204, <<>>)
    end
  end

  describe "HTTP/1.1 handshake" do
    test "accepts well formed requests", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    end

    test "does not accept non-GET requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "POST", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-HTTP/1.1 requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/",
        [
          "Host: server.example.com",
          "Upgrade: WeBsOcKeT",
          "Connection: UpGrAdE",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13"
        ],
        "1.0"
      )

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept requests without a host header", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(
        client,
        "GET",
        "/",
        [
          "Upgrade: WeBsOcKeT",
          "Connection: UpGrAdE",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13"
        ],
        "1.0"
      )

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-websocket upgrade requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: bogus",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept non-upgrade requests", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: close",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept requests without a request key", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "does not accept requests without a version of 13", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 12"
      ])

      assert {:ok, "204 No Content", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)
    end

    test "negotiates permessage-deflate if so configured", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      assert Keyword.get(headers, :"sec-websocket-extensions") == "permessage-deflate"
    end

    test "negotiates permessage-deflate empty client_max_window_bits parameter", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;client_max_window_bits"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;client_max_window_bits=15"
    end

    test "negotiates permessage-deflate numeric client_max_window_bits parameter", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;client_max_window_bits=12"
      ])

      V

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;client_max_window_bits=12"
    end

    test "negotiates permessage-deflate numeric server_max_window_bits parameter", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;server_max_window_bits=12"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;server_max_window_bits=12"
    end

    test "negotiates permessage-deflate server_no_context_takeover parameter", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;server_no_context_takeover"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;server_no_context_takeover"
    end

    test "negotiates permessage-deflate client_no_context_takeover parameter", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;client_no_context_takeover"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;client_no_context_takeover"
    end

    test "falls back to later permessage-deflate offers", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;server_max_window_bits=99,permessage-deflate;client_max_window_bits"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      assert Keyword.get(headers, :"sec-websocket-extensions") ==
               "permessage-deflate;client_max_window_bits=15"
    end

    test "does not negotiate permessage-deflate if not configured", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;client_max_window_bits"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      refute Keyword.get(headers, :"sec-websocket-extensions")
    end

    test "does not negotiate unknown extensions", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: not-a-real-extension"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      refute Keyword.get(headers, :"sec-websocket-extensions")
    end

    test "does not negotiate permessage-deflate if the client sends invalid options", context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate; this_is_not_an_option"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      refute Keyword.get(headers, :"sec-websocket-extensions")
    end

    test "does not negotiate permessage-deflate if the client sends repeat option values",
         context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;client_max_window_bits;client_max_window_bits"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      refute Keyword.get(headers, :"sec-websocket-extensions")
    end

    test "does not negotiate permessage-deflate if the client sends invalid option values",
         context do
      client = SimpleWebSocketClient.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/compress", [
        "Host: server.example.com",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Extensions: permessage-deflate;server_max_window_bits"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :upgrade) == "websocket"
      assert Keyword.get(headers, :connection) == "Upgrade"
      assert Keyword.get(headers, :"sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      refute Keyword.get(headers, :"sec-websocket-extensions")
    end
  end
end
