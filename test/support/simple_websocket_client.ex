defmodule SimpleWebSocketClient do
  @moduledoc false

  alias Bandit.WebSocket.Frame

  defdelegate tcp_client(context), to: ClientHelpers

  def http1_handshake(client, query \\ []) do
    :gen_tcp.send(client, """
    GET /?#{URI.encode_query(query)} HTTP/1.1\r
    Host: server.example.com\r
    Upgrade: websocket\r
    Connection: Upgrade\r
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
    Sec-WebSocket-Version: 13\r
    \r
    """)

    {:ok, response} = :gen_tcp.recv(client, 237)

    [
      "HTTP/1.1 101 Switching Protocols",
      "date: " <> _date,
      "content-length: 0",
      "cache-control: max-age=0, private, must-revalidate",
      "upgrade: websocket",
      "connection: Upgrade",
      "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=",
      "",
      ""
    ] = String.split(response, "\r\n")
  end

  def connection_closed_for_reading?(client) do
    :gen_tcp.recv(client, 0) == {:error, :closed}
  end

  def connection_closed_for_writing?(client) do
    :gen_tcp.send(client, <<>>) == {:error, :closed}
  end

  def recv_text_frame(client) do
    {:ok, 0x8, 0x1, body} = recv_frame(client)
    {:ok, body}
  end

  def recv_binary_frame(client) do
    {:ok, 0x8, 0x2, body} = recv_frame(client)
    {:ok, body}
  end

  def recv_connection_close_frame(client) do
    {:ok, 0x8, 0x8, body} = recv_frame(client)
    {:ok, body}
  end

  def recv_ping_frame(client) do
    {:ok, 0x8, 0x9, body} = recv_frame(client)
    {:ok, body}
  end

  def recv_pong_frame(client) do
    {:ok, 0x8, 0xA, body} = recv_frame(client)
    {:ok, body}
  end

  defp recv_frame(client) do
    {:ok, header} = :gen_tcp.recv(client, 2)
    <<flags::4, opcode::4, 0::1, length::7>> = header

    {:ok, data} =
      case length do
        0 ->
          {:ok, <<>>}

        126 ->
          {:ok, <<length::16>>} = :gen_tcp.recv(client, 2)
          :gen_tcp.recv(client, length)

        127 ->
          {:ok, <<length::64>>} = :gen_tcp.recv(client, 8)
          :gen_tcp.recv(client, length)

        length ->
          :gen_tcp.recv(client, length)
      end

    {:ok, flags, opcode, data}
  end

  def send_continuation_frame(client, data, flags \\ 0x8) do
    send_frame(client, flags, 0x0, data)
  end

  def send_text_frame(client, data, flags \\ 0x8) do
    send_frame(client, flags, 0x1, data)
  end

  def send_binary_frame(client, data, flags \\ 0x8) do
    send_frame(client, flags, 0x2, data)
  end

  def send_connection_close_frame(client, reason) do
    send_frame(client, 0x8, 0x8, <<reason::16>>)
  end

  def send_ping_frame(client, data) do
    send_frame(client, 0x8, 0x9, data)
  end

  def send_pong_frame(client, data) do
    send_frame(client, 0x8, 0xA, data)
  end

  defp send_frame(client, flags, opcode, data) do
    mask = :rand.uniform(1_000_000)
    masked_data = Frame.mask(data, mask)

    mask_flag_and_size =
      case byte_size(masked_data) do
        size when size <= 125 -> <<1::1, size::7>>
        size when size <= 65_535 -> <<1::1, 126::7, size::16>>
        size -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(client, [<<flags::4, opcode::4>>, mask_flag_and_size, <<mask::32>>, masked_data])
  end
end
