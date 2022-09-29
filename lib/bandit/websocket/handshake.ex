defmodule Bandit.WebSocket.Handshake do
  @moduledoc false
  # Functions to support WebSocket handshaking as described in RFC6455§4.2

  import Plug.Conn

  def handshake?(%Plug.Conn{} = conn) do
    case get_http_protocol(conn) do
      :"HTTP/1.1" ->
        # Cases from RFC6455§4.2.1
        conn.method == "GET" and
          get_req_header(conn, "host") != [] and
          header_contains?(conn, "upgrade", "websocket") and
          header_contains?(conn, "connection", "upgrade") and
          match?([<<_::binary>>], get_req_header(conn, "sec-websocket-key")) and
          get_req_header(conn, "sec-websocket-version") == ["13"]

      _ ->
        false
    end
  end

  def send_handshake(%Plug.Conn{} = conn) do
    # Taken from RFC6455§4.2.2/5. Note that we can take for granted the existence of the
    # sec-websocket-key header in the request, since we check for it in the handshake? call above
    [client_key] = get_req_header(conn, "sec-websocket-key")
    concatenated_key = client_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    hashed_key = :crypto.hash(:sha, concatenated_key)
    server_key = Base.encode64(hashed_key)

    conn
    |> resp(101, "")
    |> put_resp_header("upgrade", "websocket")
    |> put_resp_header("connection", "Upgrade")
    |> put_resp_header("sec-websocket-accept", server_key)
    |> send_resp()
  end

  defp header_contains?(conn, field, value) do
    conn
    |> get_req_header(field)
    |> Enum.map(&String.downcase(&1, :ascii))
    |> Enum.member?(String.downcase(value, :ascii))
  end
end
