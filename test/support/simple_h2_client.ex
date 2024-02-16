defmodule SimpleH2Client do
  @moduledoc false

  import Bitwise

  def tls_client(context), do: Transport.tls_client(context, ["h2"])

  def setup_connection(context) do
    socket = tls_client(context)
    exchange_prefaces(socket)
    exchange_client_settings(socket)
    socket
  end

  def exchange_prefaces(socket) do
    Transport.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>} = Transport.recv(socket, 9)
    Transport.send(socket, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)
  end

  def exchange_client_settings(socket, settings \\ <<>>) do
    Transport.send(socket, <<IO.iodata_length(settings)::24, 4, 0, 0, 0, 0, 0>>)
    Transport.send(socket, settings)
    {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>} = Transport.recv(socket, 9)
  end

  def connection_alive?(socket) do
    Transport.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
    Transport.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
  end

  def recv_goaway_and_close(socket) do
    {:ok, <<0, 0, 8, 7, 0, 0, 0, 0, 0, last_stream_id::32, error_code::32>>} =
      Transport.recv(socket, 17)

    {:error, :closed} = Transport.recv(socket, 0)

    {:ok, last_stream_id, error_code}
  end

  def send_goaway(socket, last_stream_id, error_code) do
    Transport.send(socket, <<0, 0, 8, 7, 0, 0, 0, 0, 0, last_stream_id::32, error_code::32>>)
  end

  def send_simple_headers(socket, stream_id, verb, path, port, ctx \\ HPAX.new(4096)) do
    {verb, end_stream} =
      case verb do
        :get -> {"GET", true}
        :head -> {"HEAD", true}
        :post -> {"POST", false}
      end

    send_headers(
      socket,
      stream_id,
      end_stream,
      [
        {":method", verb},
        {":path", path},
        {":scheme", "https"},
        {":authority", "localhost:#{port}"}
      ],
      ctx
    )
  end

  def send_headers(socket, stream_id, end_stream, headers, ctx \\ HPAX.new(4096)) do
    {headers, _} = headers |> Enum.map(fn {k, v} -> {:store, k, v} end) |> HPAX.encode(ctx)
    flags = if end_stream, do: 0x05, else: 0x04

    Transport.send(socket, [
      <<IO.iodata_length(headers)::24, 1::8, flags::8, 0::1, stream_id::31>>,
      headers
    ])

    {:ok, ctx}
  end

  def send_priority(socket, stream_id, dependent_stream_id, weight) do
    Transport.send(socket, <<0, 0, 5, 2, 0, stream_id::32, dependent_stream_id::32, weight::8>>)
  end

  def successful_response?(socket, stream_id, end_stream, ctx \\ HPAX.new(4096)) do
    {:ok, ^stream_id, ^end_stream, [{":status", "200"} | _], _ctx} = recv_headers(socket, ctx)
  end

  def recv_headers(socket, ctx \\ HPAX.new(4096)) do
    {:ok, <<length::24, 1::8, flags::8, 0::1, stream_id::31>>} = Transport.recv(socket, 9)
    {:ok, header_block} = Transport.recv(socket, length)
    {:ok, headers, ctx} = HPAX.decode(header_block, ctx)
    {:ok, stream_id, (flags &&& 0x01) == 0x01, headers, ctx}
  end

  def send_body(socket, stream_id, end_stream, body) do
    flags = if end_stream, do: 0x01, else: 0x00

    Transport.send(socket, [
      <<IO.iodata_length(body)::24, 0::8, flags::8, 0::1, stream_id::31>>,
      body
    ])
  end

  def send_window_update(socket, stream_id, increment) do
    Transport.send(socket, <<4::24, 8::8, 0::8, 0::1, stream_id::31, 0::1, increment::31>>)
  end

  def recv_window_update(socket) do
    {:ok, <<4::24, 8::8, 0::8, 0::1, stream_id::31, 0::1, update::31>>} =
      Transport.recv(socket, 13)

    {:ok, stream_id, update}
  end

  def recv_body(socket) do
    {:ok, <<body_length::24, 0::8, flags::8, 0::1, stream_id::31>>} = Transport.recv(socket, 9)

    if body_length == 0 do
      {:ok, stream_id, (flags &&& 0x01) == 0x01, <<>>}
    else
      {:ok, body} = Transport.recv(socket, body_length)
      {:ok, stream_id, (flags &&& 0x01) == 0x01, body}
    end
  end

  def send_rst_stream(socket, stream_id, error_code) do
    Transport.send(socket, [<<0, 0, 4, 3, 0, 0::1, stream_id::31>>, <<error_code::32>>])
  end

  def recv_rst_stream(socket) do
    {:ok, <<0, 0, 4, 3, 0, 0::1, stream_id::31, error_code::32>>} = Transport.recv(socket, 13)
    {:ok, stream_id, error_code}
  end
end
