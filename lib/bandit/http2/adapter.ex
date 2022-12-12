defmodule Bandit.HTTP2.Adapter do
  @moduledoc false
  # Implements the Plug-facing `Plug.Conn.Adapter` behaviour. These functions provide the primary
  # mechanism for Plug applications to interact with a client, including functions to read the
  # client body (if sent) and send response information back to the client.

  @behaviour Plug.Conn.Adapter

  defstruct connection: nil, peer: nil, stream_id: nil, end_stream: false

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          connection: Bandit.HTTP2.Connection.t(),
          peer: Plug.Conn.Adapter.peer_data(),
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          end_stream: boolean()
        }

  # As described in the header documentation for the `Bandit.HTTP2.StreamTask` module, we
  # purposefully use raw `receive` message patterns here in order to facilitate an imperatively
  # structured blocking interface. Comments inline.
  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{end_stream: true}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  def read_req_body(%__MODULE__{} = adapter, opts) do
    timeout = Keyword.get(opts, :read_timeout, 15_000)
    length = Keyword.get(opts, :length, 8_000_000)
    do_read_req_body(adapter, timeout, length, [])
  end

  defp do_read_req_body(adapter, timeout, remaining_length, acc) do
    receive do
      {:data, data} ->
        acc = [data | acc]
        remaining_length = remaining_length - byte_size(data)

        if remaining_length >= 0 do
          do_read_req_body(adapter, timeout, remaining_length, acc)
        else
          {:more, wrap_req_body(acc), adapter}
        end

      :end_stream ->
        {:ok, wrap_req_body(acc), %{adapter | end_stream: true}}
    after
      timeout -> {:more, wrap_req_body(acc), adapter}
    end
  end

  defp wrap_req_body(data) do
    data |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, body) do
    if IO.iodata_length(body) == 0 do
      send_headers(adapter, status, headers, true)
    else
      send_headers(adapter, status, headers, false)
      send_data(adapter, body, true)
    end

    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{} = adapter, status, headers, path, offset, length) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    length = if length == :all, do: size - offset, else: length

    cond do
      offset + length == size && offset == 0 ->
        send_chunked(adapter, status, headers)

        # As per Plug documentation `chunk/2` always returns `:ok`
        # and webservers SHOULDN'T modify any state on sending a chunk,
        # so there is no need to check the return value
        # of `chunk/2` and the adapter doesn't need updating.
        path
        |> File.stream!([], 2048)
        |> Enum.each(&chunk(adapter, &1))

        # Send empty chunk to indicate the end of stream
        chunk(adapter, "")

        {:ok, nil, adapter}

      offset + length < size ->
        with {:ok, fd} <- :file.open(path, [:raw, :binary]),
             {:ok, data} <- :file.pread(fd, offset, length) do
          send_headers(adapter, status, headers, false)
          send_data(adapter, data, true)
          {:ok, nil, adapter}
        end

      true ->
        raise "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    send_headers(adapter, status, headers, false)
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, chunk) do
    # Sending an empty chunk implicitly ends the stream. This is a bit of an undefined corner of
    # the Plug.Conn.Adapter behaviour (see https://github.com/elixir-plug/plug/pull/535 for
    # details) and closing the stream here carves closest to the underlying HTTP/1.1 behaviour
    # (RFC7230§4.1). The whole notion of chunked encoding is moot in HTTP/2 anyway (RFC7540§8.1)
    # so this entire section of the API is a bit slanty regardless.
    send_data(adapter, chunk, chunk == <<>>)
    :ok
  end

  @impl Plug.Conn.Adapter
  def inform(adapter, status, headers) do
    headers = split_cookies(headers)
    headers = [{":status", to_string(status)} | headers]

    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, false})
  end

  @impl Plug.Conn.Adapter
  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_adapter, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{peer: peer}), do: peer

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{}), do: :"HTTP/2"

  defp send_headers(adapter, status, headers, end_stream) do
    headers = split_cookies(headers)

    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end

    headers = [{":status", to_string(status)} | headers]

    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, end_stream})
  end

  defp send_data(adapter, data, end_stream) do
    GenServer.call(
      adapter.connection,
      {:send_data, adapter.stream_id, data, end_stream},
      :infinity
    )
  end

  defp split_cookies(headers) do
    headers
    |> Enum.flat_map(fn
      {"cookie", cookie} ->
        cookie |> String.split("; ") |> Enum.map(fn crumb -> {"cookie", crumb} end)

      {header, value} ->
        [{header, value}]
    end)
  end
end
