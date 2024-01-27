defmodule Bandit.HTTP2.Adapter do
  @moduledoc false
  # Implements the Plug-facing `Plug.Conn.Adapter` behaviour. These functions provide the primary
  # mechanism for Plug applications to interact with a client, including functions to read the
  # client body (if sent) and send response information back to the client. The concerns in this
  # module are broadly about the semantics of HTTP in general, and less about transport-specific
  # concerns; those are covered in `Bandit.HTTP2.Stream`

  @behaviour Plug.Conn.Adapter

  defstruct stream: nil,
            owner_pid: nil,
            method: nil,
            content_encoding: nil,
            status: nil,
            metrics: nil,
            opts: nil

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          stream: Bandit.HTTP2.Stream.t(),
          owner_pid: pid() | nil,
          method: Plug.Conn.method() | nil,
          content_encoding: String.t() | nil,
          status: Plug.Conn.status() | nil,
          metrics: map(),
          opts: keyword()
        }

  def init(stream, method, headers, owner, opts) do
    content_encoding =
      Bandit.Compression.negotiate_content_encoding(
        Bandit.Headers.get_header(headers, "accept-encoding"),
        Keyword.get(opts, :compress, true)
      )

    %__MODULE__{
      stream: stream,
      method: method,
      owner_pid: owner,
      opts: opts,
      content_encoding: content_encoding,
      metrics: %{req_header_end_time: Bandit.Telemetry.monotonic_time()}
    }
  end

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{} = adapter, opts) do
    validate_calling_process!(adapter)

    metrics =
      adapter.metrics
      |> Map.put_new_lazy(:req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

    case Bandit.HTTP2.Stream.read_data(adapter.stream, opts) do
      {:ok, body, stream} ->
        body = IO.iodata_to_binary(body)

        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(body), &(&1 + byte_size(body)))
          |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

        {:ok, body, %{adapter | stream: stream, metrics: metrics}}

      {:more, body, stream} ->
        body = IO.iodata_to_binary(body)

        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(body), &(&1 + byte_size(body)))

        {:more, body, %{adapter | stream: stream, metrics: metrics}}
    end
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
    adapter = %{adapter | status: status}

    adapter =
      if body_bytes == 0 || !send_resp_body?(adapter) do
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
    adapter = %{adapter | status: status}

    adapter =
      cond do
        !send_resp_body?(adapter) ->
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

    adapter = %{adapter | status: status}

    if send_resp_body?(adapter) do
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

    validate_calling_process!(adapter)

    if send_resp_body?(adapter) do
      byte_size = chunk |> IO.iodata_length()
      adapter = send_data(adapter, chunk, byte_size == 0)

      if byte_size == 0 do
        metrics = Map.put(adapter.metrics, :resp_end_time, Bandit.Telemetry.monotonic_time())
        {:ok, nil, %{adapter | metrics: metrics}}
      else
        {:ok, nil, adapter}
      end
    else
      {:ok, nil, adapter}
    end
  end

  @impl Plug.Conn.Adapter
  def inform(adapter, status, headers) do
    validate_calling_process!(adapter)
    stream = Bandit.HTTP2.Stream.send_headers(adapter.stream, status, headers, false)
    {:ok, %{adapter | stream: stream}}
  end

  @impl Plug.Conn.Adapter
  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_adapter, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(req), do: Bandit.TransportInfo.peer_data(req.stream.transport_info)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{}), do: :"HTTP/2"

  defp send_resp_body?(%{method: "HEAD"}), do: false
  defp send_resp_body?(%{status: 204}), do: false
  defp send_resp_body?(%{status: 304}), do: false
  defp send_resp_body?(_req), do: true

  defp send_headers(adapter, status, headers, end_stream) do
    metrics =
      adapter.metrics
      |> Map.put_new_lazy(:resp_start_time, &Bandit.Telemetry.monotonic_time/0)
      |> Map.put(:resp_body_bytes, 0)

    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end

    stream = Bandit.HTTP2.Stream.send_headers(adapter.stream, status, headers, end_stream)
    %{adapter | stream: stream, metrics: metrics}
  end

  defp send_data(adapter, data, end_stream) do
    stream = Bandit.HTTP2.Stream.send_data(adapter.stream, data, end_stream)
    bytes_sent = IO.iodata_length(data)
    metrics = adapter.metrics |> Map.update(:resp_body_bytes, bytes_sent, &(&1 + bytes_sent))
    %{adapter | stream: stream, metrics: metrics}
  end

  defp validate_calling_process!(%{owner_pid: owner}) when owner == self(), do: :ok
  defp validate_calling_process!(_), do: raise("Adapter functions must be called by stream owner")
end
