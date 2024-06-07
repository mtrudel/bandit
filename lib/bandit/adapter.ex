defmodule Bandit.Adapter do
  @moduledoc false
  # Implements the Plug-facing `Plug.Conn.Adapter` behaviour. These functions provide the primary
  # mechanism for Plug applications to interact with a client, including functions to read the
  # client body (if sent) and send response information back to the client. The concerns in this
  # module are broadly about the semantics of HTTP in general, and less about transport-specific
  # concerns, which are managed by the underlying `Bandit.HTTPTransport` implementation

  @behaviour Plug.Conn.Adapter

  defstruct transport: nil,
            owner_pid: nil,
            method: nil,
            status: nil,
            content_encoding: nil,
            upgrade: nil,
            metrics: %{},
            opts: []

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          transport: Bandit.HTTPTransport.t(),
          owner_pid: pid() | nil,
          method: Plug.Conn.method() | nil,
          status: Plug.Conn.status() | nil,
          content_encoding: String.t(),
          upgrade: nil | {:websocket, opts :: keyword(), websocket_opts :: keyword()},
          metrics: %{},
          opts: %{
            required(:http) => Bandit.http_options(),
            required(:websocket) => Bandit.websocket_options()
          }
        }

  def init(owner_pid, transport, method, headers, opts) do
    content_encoding =
      Bandit.Compression.negotiate_content_encoding(
        Bandit.Headers.get_header(headers, "accept-encoding"),
        Keyword.get(opts.http, :compress, true)
      )

    %__MODULE__{
      transport: transport,
      owner_pid: owner_pid,
      method: method,
      content_encoding: content_encoding,
      metrics: %{req_header_end_time: Bandit.Telemetry.monotonic_time()},
      opts: opts
    }
  end

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{} = adapter, opts) do
    validate_calling_process!(adapter)

    metrics =
      adapter.metrics
      |> Map.put_new_lazy(:req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

    case Bandit.HTTPTransport.read_data(adapter.transport, opts) do
      {:ok, body, transport} ->
        body = IO.iodata_to_binary(body)

        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(body), &(&1 + byte_size(body)))
          |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

        {:ok, body, %{adapter | transport: transport, metrics: metrics}}

      {:more, body, transport} ->
        body = IO.iodata_to_binary(body)

        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(body), &(&1 + byte_size(body)))

        {:more, body, %{adapter | transport: transport, metrics: metrics}}
    end
  end

  ##################
  # Response Sending
  ##################

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, body) do
    validate_calling_process!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()
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

          deflate_options = Keyword.get(adapter.opts.http, :deflate_options, [])
          deflated_body = Bandit.Compression.compress(body, content_encoding, deflate_options)
          headers = [{"content-encoding", adapter.content_encoding} | headers]
          {deflated_body, headers, metrics}

        _ ->
          {body, headers, %{}}
      end

    compress = Keyword.get(adapter.opts.http, :compress, true)
    headers = if compress, do: [{"vary", "accept-encoding"} | headers], else: headers

    length = IO.iodata_length(body)
    headers = Bandit.Headers.add_content_length(headers, length, status, adapter.method)

    metrics =
      adapter.metrics
      |> Map.put(:resp_start_time, start_time)
      |> Map.merge(compression_metrics)

    adapter =
      %{adapter | metrics: metrics}
      |> send_headers(status, headers, :raw)
      |> send_data(body, true)

    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def send_file(
        %__MODULE__{} = adapter,
        status,
        headers,
        path,
        offset,
        length
      ) do
    validate_calling_process!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    length = if length == :all, do: size - offset, else: length

    if offset + length <= size do
      headers = Bandit.Headers.add_content_length(headers, length, status, adapter.method)
      adapter = send_headers(adapter, status, headers, :raw)

      {socket, bytes_actually_written} =
        if send_resp_body?(adapter),
          do: {Bandit.HTTPTransport.sendfile(adapter.transport, path, offset, length), length},
          else: {adapter.transport, 0}

      metrics =
        adapter.metrics
        |> Map.put(:resp_body_bytes, bytes_actually_written)
        |> Map.put(:resp_start_time, start_time)
        |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

      {:ok, nil, %{adapter | transport: socket, metrics: metrics}}
    else
      raise "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    validate_calling_process!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()
    metrics = Map.put(adapter.metrics, :resp_start_time, start_time)
    adapter = %{adapter | metrics: metrics}
    {:ok, nil, send_headers(adapter, status, headers, :chunk_encoded)}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, chunk) do
    # Sending an empty chunk implicitly ends the response. This is a bit of an undefined corner of
    # the Plug.Conn.Adapter behaviour (see https://github.com/elixir-plug/plug/pull/535 for
    # details) and ending the response here carves closest to the underlying HTTP/1.1 behaviour
    # (RFC9112§7.1). Since there is no notion of chunked encoding is in HTTP/2 anyway (RFC9113§8.1)
    # this entire section of the API is a bit slanty regardless.

    validate_calling_process!(adapter)

    # chunk/2 is unique among Plug.Conn.Adapter's sending callbacks in that it can return an error
    # tuple instead of just raising or dying on error. Rescue here to implement this
    try do
      {:ok, nil, send_data(adapter, chunk, IO.iodata_length(chunk) == 0)}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  @impl Plug.Conn.Adapter
  def inform(%__MODULE__{} = adapter, status, headers) do
    validate_calling_process!(adapter)
    # It's a bit weird to be casing on the underlying version here, but whether or not to send
    # an informational response is actually defined in RFC9110§15.2 so we consider it as an aspect
    # of semantics that belongs here and not in the underlying transport
    if get_http_protocol(adapter) == :"HTTP/1.0" do
      {:error, :not_supported}
    else
      {:ok, send_headers(adapter, status, headers, :inform)}
    end
  end

  defp send_headers(adapter, status, headers, body_disposition) do
    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end

    adapter = %{adapter | status: status}

    body_disposition = if send_resp_body?(adapter), do: body_disposition, else: :no_body

    socket =
      Bandit.HTTPTransport.send_headers(adapter.transport, status, headers, body_disposition)

    %{adapter | transport: socket}
  end

  defp send_data(adapter, data, end_request) do
    socket =
      if send_resp_body?(adapter),
        do: Bandit.HTTPTransport.send_data(adapter.transport, data, end_request),
        else: adapter.transport

    data_size = IO.iodata_length(data)
    metrics = Map.update(adapter.metrics, :resp_body_bytes, data_size, &(&1 + data_size))

    metrics =
      if end_request,
        do: Map.put(metrics, :resp_end_time, Bandit.Telemetry.monotonic_time()),
        else: metrics

    %{adapter | transport: socket, metrics: metrics}
  end

  defp send_resp_body?(%{method: "HEAD"}), do: false
  defp send_resp_body?(%{status: 204}), do: false
  defp send_resp_body?(%{status: 304}), do: false
  defp send_resp_body?(_adapter), do: true

  @impl Plug.Conn.Adapter
  def upgrade(%__MODULE__{} = adapter, protocol, opts) do
    if Keyword.get(adapter.opts.websocket, :enabled, true) &&
         Bandit.HTTPTransport.supported_upgrade?(adapter.transport, protocol),
       do: {:ok, %{adapter | upgrade: {protocol, opts, adapter.opts.websocket}}},
       else: {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def push(_adapter, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{} = adapter) do
    adapter.transport
    |> Bandit.HTTPTransport.transport_info()
    |> Bandit.TransportInfo.peer_data()
  end

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{} = adapter),
    do: Bandit.HTTPTransport.version(adapter.transport)

  defp validate_calling_process!(%{owner_pid: owner}) when owner == self(), do: :ok
  defp validate_calling_process!(_), do: raise("Adapter functions must be called by stream owner")
end
