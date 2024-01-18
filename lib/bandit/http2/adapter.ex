defmodule Bandit.HTTP2.Adapter do
  @moduledoc false
  # Implements the Plug-facing `Plug.Conn.Adapter` behaviour. These functions provide the primary
  # mechanism for Plug applications to interact with a client, including functions to read the
  # client body (if sent) and send response information back to the client.

  @behaviour Plug.Conn.Adapter

  defstruct connection: nil,
            owner_pid: nil,
            transport_info: nil,
            stream_id: nil,
            end_stream: false,
            recv_window_size: 65_535,
            send_window_size: nil,
            method: nil,
            content_encoding: nil,
            pending_content_length: nil,
            metrics: %{},
            opts: []

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          connection: pid(),
          owner_pid: pid() | nil,
          transport_info: Bandit.TransportInfo.t(),
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          end_stream: boolean(),
          recv_window_size: non_neg_integer(),
          send_window_size: non_neg_integer(),
          method: Plug.Conn.method() | nil,
          content_encoding: String.t() | nil,
          pending_content_length: non_neg_integer() | nil,
          metrics: map(),
          opts: keyword()
        }

  def init(connection, owner, transport_info, stream_id, send_window_size, opts) do
    %__MODULE__{
      connection: connection,
      owner_pid: owner,
      transport_info: transport_info,
      stream_id: stream_id,
      send_window_size: send_window_size,
      opts: opts
    }
  end

  def add_end_header_metric(adapter) do
    %{
      adapter
      | metrics: Map.put(adapter.metrics, :req_header_end_time, Bandit.Telemetry.monotonic_time())
    }
  end

  # We purposefully use raw `receive` message patterns here in order to facilitate an imperatively
  # structured blocking interface as required by `Plug.Conn.Adapter`. This is very unconventional
  # but also safe, so long as the receive patterns expressed below are extremely tight.
  #
  # The events which 'unblock' these conditions come from within the Connection, and are pushed
  # down to streams via calls on `Bandit.HTTP2.StreamProcess` as a fundamental design decision
  # (rather than having stream processes query the connection directly).
  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{end_stream: true}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  def read_req_body(%__MODULE__{} = adapter, opts) do
    validate_calling_process!(adapter)
    timeout = Keyword.get(opts, :read_timeout, 15_000)
    length = Keyword.get(opts, :length, 8_000_000)
    do_read_req_body(adapter, timeout, length, [])
  end

  defp do_read_req_body(adapter, timeout, remaining_length, acc) do
    metrics =
      adapter.metrics
      |> Map.put_new_lazy(:req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

    adapter = %{adapter | metrics: metrics}

    receive do
      {:data, data} ->
        {new_window, increment} =
          Bandit.HTTP2.FlowControl.compute_recv_window(adapter.recv_window_size, byte_size(data))

        if increment > 0 do
          GenServer.call(
            adapter.connection,
            {:send_recv_window_update, adapter.stream_id, increment}
          )
        end

        adapter = %{adapter | recv_window_size: new_window}

        acc = [data | acc]
        remaining_length = remaining_length - byte_size(data)

        if remaining_length >= 0 do
          do_read_req_body(adapter, timeout, remaining_length, acc)
        else
          return_more(acc, adapter)
        end

      :end_stream ->
        bytes_read = IO.iodata_length(acc)

        pending_content_length =
          case adapter.pending_content_length do
            nil -> nil
            pending_content_length -> pending_content_length - bytes_read
          end

        if pending_content_length in [nil, 0] do
          metrics =
            adapter.metrics
            |> Map.update(:req_body_bytes, bytes_read, &(&1 + bytes_read))
            |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

          {:ok, wrap_req_body(acc),
           %{
             adapter
             | end_stream: true,
               pending_content_length: pending_content_length,
               metrics: metrics
           }}
        else
          raise Bandit.HTTP2.Stream.StreamError,
            message: "Received end of stream with #{pending_content_length} byte(s) pending",
            method: adapter.method,
            error_code: Bandit.HTTP2.Errors.protocol_error()
        end
    after
      timeout -> return_more(acc, adapter)
    end
  end

  defp return_more(data, adapter) do
    bytes_read = IO.iodata_length(data)

    pending_content_length =
      case adapter.pending_content_length do
        nil -> nil
        pending_content_length -> pending_content_length - bytes_read
      end

    metrics =
      adapter.metrics
      |> Map.update(:req_body_bytes, bytes_read, &(&1 + bytes_read))

    {:more, wrap_req_body(data),
     %{adapter | metrics: metrics, pending_content_length: pending_content_length}}
  end

  defp wrap_req_body(data) do
    data |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, body) do
    validate_calling_process!(adapter)
    response_content_encoding_header = Bandit.Headers.get_header(headers, "content-encoding")

    response_has_strong_etag =
      case Bandit.Headers.get_header(headers, "etag") do
        nil -> false
        "\W" <> _rest -> false
        _strong_etag -> true
      end

    response_indicates_no_transform =
      case Bandit.Headers.get_header(headers, "cache-control") do
        nil -> false
        header -> "no-transform" in Plug.Conn.Utils.list(header)
      end

    raw_body_bytes = IO.iodata_length(body)

    {body, headers, compression_metrics} =
      case {body, adapter.content_encoding, response_content_encoding_header,
            response_has_strong_etag, response_indicates_no_transform} do
        {body, content_encoding, nil, false, false}
        when raw_body_bytes > 0 and not is_nil(content_encoding) ->
          metrics = %{
            resp_uncompressed_body_bytes: raw_body_bytes,
            resp_compression_method: content_encoding
          }

          deflate_options = Keyword.get(adapter.opts, :deflate_options, [])
          body = Bandit.Compression.compress(body, adapter.content_encoding, deflate_options)
          headers = [{"content-encoding", adapter.content_encoding} | headers]
          {body, headers, metrics}

        _ ->
          {body, headers, %{}}
      end

    compress = Keyword.get(adapter.opts, :compress, true)
    headers = if compress, do: [{"vary", "accept-encoding"} | headers], else: headers
    body_bytes = IO.iodata_length(body)
    headers = Bandit.Headers.add_content_length(headers, body_bytes, status)

    adapter =
      if body_bytes == 0 || !send_resp_body?(adapter, status) do
        adapter
        |> send_headers(status, headers, true)
      else
        adapter
        |> send_headers(status, headers, false)
        |> send_data(body, true)
      end

    metrics =
      adapter.metrics
      |> Map.merge(compression_metrics)
      |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

    {:ok, nil, %{adapter | metrics: metrics}}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{} = adapter, status, headers, path, offset, length) do
    validate_calling_process!(adapter)
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    length = if length == :all, do: size - offset, else: length
    headers = Bandit.Headers.add_content_length(headers, length, status)

    adapter =
      cond do
        !send_resp_body?(adapter, status) ->
          send_headers(adapter, status, headers, true)

        offset + length == size && offset == 0 ->
          adapter = send_headers(adapter, status, headers, false)

          path
          |> File.stream!([], 2048)
          |> Enum.reduce(adapter, fn chunk, adapter -> send_data(adapter, chunk, false) end)
          |> send_data(<<>>, true)

        offset + length <= size ->
          case :file.open(path, [:raw, :binary]) do
            {:ok, fd} ->
              try do
                with {:ok, data} <- :file.pread(fd, offset, length) do
                  adapter
                  |> send_headers(status, headers, false)
                  |> send_data(data, true)
                end
              after
                :file.close(fd)
              end

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          raise "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"
      end

    metrics = Map.put(adapter.metrics, :resp_end_time, Bandit.Telemetry.monotonic_time())

    {:ok, nil, %{adapter | metrics: metrics}}
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    validate_calling_process!(adapter)

    if send_resp_body?(adapter, status) do
      {:ok, nil, send_headers(adapter, status, headers, false)}
    else
      {:ok, nil, send_headers(adapter, status, headers, true)}
    end
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, chunk) do
    # Sending an empty chunk implicitly ends the stream. This is a bit of an undefined corner of
    # the Plug.Conn.Adapter behaviour (see https://github.com/elixir-plug/plug/pull/535 for
    # details) and closing the stream here carves closest to the underlying HTTP/1.1 behaviour
    # (RFC9112§7.1). The whole notion of chunked encoding is moot in HTTP/2 anyway (RFC9113§8.1)
    # so this entire section of the API is a bit slanty regardless.
    #
    # Moreover, if the caller is chunking out on a HEAD, 204 or 304 response, the underlying
    # stream will have been closed in send_chunked/3 above, and so this call will return an
    # `{:error, :not_owner}` error here (which we ignore, but it's still kinda odd)
    validate_calling_process!(adapter)

    byte_size = chunk |> IO.iodata_length()
    adapter = send_data(adapter, chunk, byte_size == 0)

    if byte_size == 0 do
      metrics = Map.put(adapter.metrics, :resp_end_time, Bandit.Telemetry.monotonic_time())
      {:ok, nil, %{adapter | metrics: metrics}}
    else
      {:ok, nil, adapter}
    end
  end

  @impl Plug.Conn.Adapter
  def inform(adapter, status, headers) do
    validate_calling_process!(adapter)
    headers = split_cookies(headers)
    headers = [{":status", to_string(status)} | headers]

    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, false})
  end

  @impl Plug.Conn.Adapter
  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_adapter, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{transport_info: transport_info}),
    do: Bandit.TransportInfo.peer_data(transport_info)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{}), do: :"HTTP/2"

  defp send_resp_body?(%{method: "HEAD"}, _status), do: false
  defp send_resp_body?(_req, 204), do: false
  defp send_resp_body?(_req, 304), do: false
  defp send_resp_body?(_req, _status), do: true

  defp send_headers(adapter, status, headers, end_stream) do
    metrics =
      adapter.metrics
      |> Map.put_new_lazy(:resp_start_time, &Bandit.Telemetry.monotonic_time/0)
      |> Map.put(:resp_body_bytes, 0)

    headers = split_cookies(headers)

    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end

    headers = [{":status", to_string(status)} | headers]

    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, end_stream})

    %{adapter | metrics: metrics}
  end

  defp send_data(adapter, data, end_stream) do
    adapter = wait_for_send_window(adapter, 0)
    max_bytes_to_send = max(adapter.send_window_size, 0)
    {data_to_send, bytes_to_send, rest} = split_data(data, max_bytes_to_send)

    adapter =
      if end_stream || bytes_to_send > 0 do
        GenServer.call(
          adapter.connection,
          {:send_data, adapter.stream_id, data_to_send, end_stream && byte_size(rest) == 0},
          :infinity
        )

        metrics =
          adapter.metrics |> Map.update(:resp_body_bytes, bytes_to_send, &(&1 + bytes_to_send))

        %{adapter | metrics: metrics, send_window_size: adapter.send_window_size - bytes_to_send}
      else
        adapter
      end

    if byte_size(rest) == 0 do
      adapter
    else
      adapter = wait_for_send_window(adapter, :infinity)
      send_data(adapter, rest, end_stream)
    end
  end

  defp wait_for_send_window(adapter, timeout) do
    receive do
      {:send_window_update, increment} ->
        case Bandit.HTTP2.FlowControl.update_send_window(adapter.send_window_size, increment) do
          {:ok, new_window} ->
            %{adapter | send_window_size: new_window}

          {:error, reason} ->
            raise Bandit.HTTP2.Stream.StreamError,
              message: reason,
              error_code: Bandit.HTTP2.Errors.flow_control_error()
        end
    after
      timeout -> adapter
    end
  end

  defp split_data(data, desired_length) do
    data_length = IO.iodata_length(data)

    if data_length <= desired_length do
      {data, data_length, <<>>}
    else
      <<to_send::binary-size(desired_length), rest::binary>> = IO.iodata_to_binary(data)
      {to_send, desired_length, rest}
    end
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

  defp validate_calling_process!(adapter) do
    if adapter.owner_pid != self() do
      raise "Adapter functions may only be called by the stream owner"
    end
  end
end
