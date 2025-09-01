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

  def exchange_prefaces(socket, with_settings \\ false) do
    Transport.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    {:ok, <<length::24, 4, 0, 0, 0, 0, 0>>} = Transport.recv(socket, 9)

    if with_settings and length > 0 do
      {:ok, _settings_data} = Transport.recv(socket, length)
    else
      0 = length
    end

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

  # Sending functions

  def send_body(socket, stream_id, end_stream, body) do
    flags = if end_stream, do: 0x01, else: 0x00

    Transport.send(socket, [
      <<IO.iodata_length(body)::24, 0::8, flags::8, 0::1, stream_id::31>>,
      body
    ])
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
    send_frame(socket, 1, flags, stream_id, headers)

    {:ok, ctx}
  end

  def send_priority(socket, stream_id, dependent_stream_id, weight) do
    send_frame(socket, 2, 0, stream_id, <<dependent_stream_id::32, weight::8>>)
  end

  def send_rst_stream(socket, stream_id, error_code) do
    send_frame(socket, 3, 0, stream_id, <<error_code::32>>)
  end

  def send_goaway(socket, last_stream_id, error_code) do
    send_frame(socket, 7, 0, 0, <<last_stream_id::32, error_code::32>>)
  end

  def send_window_update(socket, stream_id, increment) do
    send_frame(socket, 8, 0, stream_id, <<0::1, increment::31>>)
  end

  def send_frame(socket, type, flags, stream_id, body) do
    Transport.send(
      socket,
      [<<IO.iodata_length(body)::24, type::8, flags::8, 0::1, stream_id::31>>, body]
    )
  end

  # Receiving functions

  def successful_response?(socket, stream_id, end_stream, ctx \\ HPAX.new(4096)) do
    {:ok, ^stream_id, ^end_stream, [{":status", "200"} | _], _ctx} = recv_headers(socket, ctx)
  end

  def recv_body(socket) do
    case recv_frame(socket) do
      {:ok, :data, flags, stream_id, body} -> {:ok, stream_id, (flags &&& 0x01) == 0x01, body}
      other -> unexpected_frame!(other)
    end
  end

  def recv_headers(socket, ctx \\ HPAX.new(4096)) do
    case recv_frame(socket) do
      {:ok, :headers, flags, stream_id, header_block} ->
        {:ok, headers, ctx} = HPAX.decode(header_block, ctx)
        {:ok, stream_id, (flags &&& 0x01) == 0x01, headers, ctx}

      other ->
        unexpected_frame!(other)
    end
  end

  def recv_rst_stream(socket) do
    case recv_frame(socket) do
      {:ok, :rst_stream, 0, stream_id, <<error_code::32>>} -> {:ok, stream_id, error_code}
      other -> unexpected_frame!(other)
    end
  end

  def recv_goaway_and_close(socket) do
    case recv_frame(socket) do
      {:ok, :goaway, 0, 0, <<last_stream_id::32, error_code::32>>} ->
        {:error, :closed} = Transport.recv(socket, 0)
        {:ok, last_stream_id, error_code}

      other ->
        unexpected_frame!(other)
    end
  end

  def recv_window_update(socket) do
    case recv_frame(socket) do
      {:ok, :window_update, 0, stream_id, <<0::1, update::31>>} -> {:ok, stream_id, update}
      other -> unexpected_frame!(other)
    end
  end

  def recv_frame(socket) do
    with {:ok, <<body_length::24, type::8, flags::8, 0::1, stream_id::31>>} <-
           Transport.recv(socket, 9) do
      if body_length > 0 do
        with {:ok, body} <- Transport.recv(socket, body_length) do
          {:ok, map_type(type), flags, stream_id, body}
        end
      else
        {:ok, map_type(type), flags, stream_id, <<>>}
      end
    end
  end

  def map_type(0), do: :data
  def map_type(1), do: :headers
  def map_type(2), do: :priority
  def map_type(3), do: :rst_stream
  def map_type(4), do: :settings
  def map_type(5), do: :push_promise
  def map_type(6), do: :ping
  def map_type(7), do: :goaway
  def map_type(8), do: :window_update
  def map_type(9), do: :continuation

  @spec unexpected_frame!(term()) :: no_return()
  def unexpected_frame!({:ok, type, _flags, _stream_id, _body}) do
    raise "Received unexpected frame #{type}"
  end
end
