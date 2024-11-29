defmodule WebSocketHTTP1HandshakeTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  setup :http_server

  defmodule MyNoopWebSock do
    use NoopWebSock
  end

  def call(conn, _opts) do
    opts = if List.first(conn.path_info) == "compress", do: [compress: true], else: []
    Plug.Conn.upgrade_adapter(conn, :websocket, {MyNoopWebSock, [], opts})
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

    test "does not set content-encoding headers", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/", [
        "Host: server.example.com",
        "Accept-Encoding: deflate",
        "Upgrade: WeBsOcKeT",
        "Connection: UpGrAdE",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ])

      assert {:ok, "101 Switching Protocols", headers, <<>>} =
               SimpleHTTP1Client.recv_reply(client)

      assert Keyword.get(headers, :"content-encoding") == nil
      assert Keyword.get(headers, :vary) == nil
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
