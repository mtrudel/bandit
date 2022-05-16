defmodule Bandit.WebSocket.HTTP1Handshake do
  @moduledoc false
  # Functions to support HTTP/1.1 based WebSocket handshaking as described in
  # RFC6455§4.2

  def http1_handshake?(%Plug.Conn{} = conn) do
    # Cases from RFC6455§4.2.1
    conn.method == "GET" &&
      Plug.Conn.get_http_protocol(conn) == :"HTTP/1.1" &&
      Plug.Conn.get_req_header(conn, "host") != [] &&
      "websocket" in Plug.Conn.get_req_header(conn, "upgrade") &&
      "Upgrade" in Plug.Conn.get_req_header(conn, "connection") &&
      match?([<<_::binary>>], Plug.Conn.get_req_header(conn, "sec-websocket-key")) &&
      Plug.Conn.get_req_header(conn, "sec-websocket-version") == ["13"]
  end

  def send_http1_handshake(socket, conn) do
    # Taken from RFC6455§4.2.2/5. Note that we can take for granted the existence
    # of the sec-websocket-key header in the request, since we check for it in
    # the handshake above
    [client_key] = Plug.Conn.get_req_header(conn, "sec-websocket-key")
    concatenated_key = client_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    hashed_key = :crypto.hash(:sha, concatenated_key)
    server_key = Base.encode64(hashed_key)

    ThousandIsland.Socket.send(socket, """
    HTTP/1.1 101 Switching Protocols\r
    Upgrade: websocket\r
    Connection: Upgrade\r
    Sec-WebSocket-Accept: #{server_key}\r
    \r
    """)
  end
end
