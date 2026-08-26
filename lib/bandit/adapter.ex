defmodule Bandit.Adapter do
  @moduledoc false
  # Implements the Plug-facing `Plug.Conn.Adapter` behaviour. These functions provide the primary
  # mechanism for Plug applications to interact with a client, including functions to read the
  # client body (if sent) and send response information back to the client. The concerns in this
  # module are broadly about the semantics of HTTP in general, and less about transport-specific
  # concerns, which are managed by the underlying `Bandit.HTTPTransport` implementation

  @behaviour Plug.Conn.Adapter
  @already_sent {:plug_conn, :sent}

  defstruct transport: nil,
            owner_pid: nil,
            usage_counter: nil,
            method: nil,
            status: nil,
            content_encoding: nil,
            compression_context: nil,
            upgrade: nil,
            expect_continue: false,
            metrics: %{},
            opts: []

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          transport: Bandit.HTTPTransport.t(),
          owner_pid: pid() | nil,
          usage_counter: {:counters.counters_ref(), non_neg_integer()},
          method: Plug.Conn.method() | nil,
          status: Plug.Conn.status() | nil,
          content_encoding: String.t(),
          compression_context: Bandit.Compression.t() | nil,
          upgrade: nil | {:websocket, opts :: keyword(), websocket_opts :: keyword()},
          expect_continue: boolean(),
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
        opts.http
      )

    %__MODULE__{
      transport: transport,
      owner_pid: owner_pid,
      method: method,
      content_encoding: content_encoding,
      expect_continue: expect_continue?(headers, Bandit.HTTPTransport.version(transport)),
      metrics: %{req_header_end_time: Bandit.Telemetry.monotonic_time()},
      opts: opts,
      usage_counter: {:counters.new(1, []), 0}
    }
  end

  defp expect_continue?(headers, version) when version in [:"HTTP/1.1", :"HTTP/2"] do
    headers |> Bandit.Headers.get_header("expect") |> safe_downcase() == "100-continue"
  end

  defp expect_continue?(_headers, _version), do: false

  defp safe_downcase(nil), do: nil
  defp safe_downcase(str), do: String.downcase(str, :ascii)

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{} = adapter, opts) do
    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)
    adapter = maybe_send_continue(adapter)

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

        {:ok, body,
         %{adapter | transport: transport, metrics: metrics} |> advance_usage_counter()}

      {:more, body, transport} ->
        body = IO.iodata_to_binary(body)

        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(body), &(&1 + byte_size(body)))

        {:more, body,
         %{adapter | transport: transport, metrics: metrics} |> advance_usage_counter()}
    end
  end

  # Only send the interim response if nothing has been sent to the client yet - if the plug
  # already sent its own informational response (e.g. explicitly called `inform/3`) or has
  # already committed a final response, `adapter.status` will be non-nil and any response
  # already unblocks a client that's waiting on Expect: 100-continue, so sending our own would
  # be redundant (and, for a final response, would corrupt the response stream).
  defp maybe_send_continue(%__MODULE__{expect_continue: true, status: nil} = adapter),
    do: send_headers(%{adapter | expect_continue: false}, 100, [], :inform)

  defp maybe_send_continue(adapter), do: adapter

  ##################
  # Response Sending
  ##################

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, body) do
    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()

    # Save an extra iodata_length by checking common cases
    empty_body? = Bandit.SocketHelpers.iodata_empty?(body)
    {headers, compression_context} = Bandit.Compression.new(adapter, status, headers, empty_body?)

    {compress_chunk, compression_context} =
      Bandit.Compression.compress_chunk(body, compression_context)

    {close_chunk, compression_metrics} = Bandit.Compression.close(compression_context)

    encoded_body = [compress_chunk | close_chunk]
    encoded_length = IO.iodata_length(encoded_body)
    headers = Bandit.Headers.add_content_length(headers, encoded_length, status, adapter.method)

    metrics =
      adapter.metrics
      |> Map.put(:resp_start_time, start_time)
      |> Map.merge(compression_metrics)

    adapter =
      %{adapter | metrics: metrics}
      |> send_headers(status, headers, :raw)
      |> send_data(encoded_body, true)
      |> advance_usage_counter()

    send(adapter.owner_pid, @already_sent)
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
    if offset < 0, do: raise("Offset cannot be negative")
    if is_number(length) && length <= 0, do: raise("Length cannot be zero or negative")

    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()
    {:ok, fileinfo} = :file.read_file_info(path, [:raw, time: :universal])
    %File.Stat{type: :regular, size: size} = File.Stat.from_record(fileinfo)
    length = if length == :all, do: size - offset, else: length

    if length >= 0 and offset + length <= size do
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

      send(adapter.owner_pid, @already_sent)
      {:ok, nil, %{adapter | transport: socket, metrics: metrics} |> advance_usage_counter()}
    else
      raise "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)
    start_time = Bandit.Telemetry.monotonic_time()
    metrics = Map.put(adapter.metrics, :resp_start_time, start_time)

    # When the caller declares a content-length up front, stream a
    # length-delimited body instead of chunked transfer-encoding. The HTTP/1
    # transport already does this (the `:chunk_encoded when has_content_length`
    # path writes raw bytes via the `:chunk_streaming` write state), and HTTP/2
    # carries the length in its header block with no framing change. Response
    # compression would rewrite the body and invalidate the declared length, so
    # it is disabled in this mode — the caller owns the exact bytes and must send
    # precisely `content-length` of them via chunk/2.
    {headers, compression_context} =
      if is_nil(Bandit.Headers.get_header(headers, "content-length")) do
        Bandit.Compression.new(adapter, status, headers, false, true)
      else
        {headers, %Bandit.Compression{method: :identity}}
      end

    adapter = %{adapter | metrics: metrics, compression_context: compression_context}
    send(adapter.owner_pid, @already_sent)

    {:ok, nil,
     adapter |> send_headers(status, headers, :chunk_encoded) |> advance_usage_counter()}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, chunk) do
    # Sending an empty chunk implicitly ends the response. This is a bit of an undefined corner of
    # the Plug.Conn.Adapter behaviour (see https://github.com/elixir-plug/plug/pull/535 for
    # details) and ending the response here carves closest to the underlying HTTP/1.1 behaviour
    # (RFC9112§7.1). Since there is no notion of chunked encoding is in HTTP/2 anyway (RFC9113§8.1)
    # this entire section of the API is a bit slanty regardless.

    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)

    # chunk/2 is unique among Plug.Conn.Adapter's sending callbacks in that it can return an error
    # tuple instead of just raising or dying on error. Rescue here to implement this. On that
    # error path no new adapter is returned, so advance_usage_counter/1 is deliberately not
    # called - Plug's documented behaviour there is for the caller to keep using its
    # already-current conn
    try do
      if Bandit.SocketHelpers.iodata_empty?(chunk) do
        {encoded_chunk, compression_metrics} =
          Bandit.Compression.close(adapter.compression_context)

        adapter = %{adapter | metrics: Map.merge(adapter.metrics, compression_metrics)}

        adapter =
          if encoded_chunk != [] do
            send_data(adapter, encoded_chunk, false)
          else
            adapter
          end

        {:ok, nil, adapter |> send_data("", true) |> advance_usage_counter()}
      else
        {encoded_chunk, compression_context} =
          Bandit.Compression.compress_chunk(chunk, adapter.compression_context)

        adapter = %{adapter | compression_context: compression_context}
        {:ok, nil, adapter |> send_data(encoded_chunk, false) |> advance_usage_counter()}
      end
    rescue
      error in Bandit.TransportError -> {:error, error.error}
      error -> {:error, Exception.message(error)}
    end
  end

  @impl Plug.Conn.Adapter
  def inform(%__MODULE__{} = adapter, status, headers) do
    validate_calling_process!(adapter)
    validate_usage_counter!(adapter)
    # It's a bit weird to be casing on the underlying version here, but whether or not to send
    # an informational response is actually defined in RFC9110§15.2 so we consider it as an aspect
    # of semantics that belongs here and not in the underlying transport
    if get_http_protocol(adapter) == :"HTTP/1.0" do
      {:error, :not_supported}
    else
      # inform/3 is unique in that headers comes in as a keyword list
      headers = Enum.map(headers, fn {header, value} -> {to_string(header), value} end)
      {:ok, adapter |> send_headers(status, headers, :inform) |> advance_usage_counter()}
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
    {socket, data_size} =
      if send_resp_body?(adapter) do
        {Bandit.HTTPTransport.send_data(adapter.transport, data, end_request),
         IO.iodata_length(data)}
      else
        {adapter.transport, 0}
      end

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
    validate_usage_counter!(adapter)

    if Keyword.get(adapter.opts.websocket, :enabled, true) &&
         Bandit.HTTPTransport.supported_upgrade?(adapter.transport, protocol),
       do:
         {:ok,
          %{adapter | upgrade: {protocol, opts, adapter.opts.websocket}}
          |> advance_usage_counter()},
       else: {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def push(_adapter, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{} = adapter),
    do: Bandit.HTTPTransport.peer_data(adapter.transport)

  @impl Plug.Conn.Adapter
  def get_sock_data(%__MODULE__{} = adapter),
    do: Bandit.HTTPTransport.sock_data(adapter.transport)

  @impl Plug.Conn.Adapter
  def get_ssl_data(%__MODULE__{} = adapter),
    do: Bandit.HTTPTransport.ssl_data(adapter.transport)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{} = adapter),
    do: Bandit.HTTPTransport.version(adapter.transport)

  defp validate_calling_process!(%{owner_pid: owner}) when owner == self(), do: :ok
  defp validate_calling_process!(_), do: raise("Adapter functions must be called by stream owner")

  # Every Plug.Conn.Adapter callback that returns an updated conn bumps the shared side of
  # usage_counter and stamps the returned adapter's local side to match. If a later call comes
  # in with an adapter whose local count is behind the shared count's current value, some other
  # (newer) copy of the conn already advanced the connection - which can only happen if this
  # adapter is a stale conn that should have been discarded. Using the conn at that point would
  # otherwise let Bandit silently misinterpret leftover socket state (e.g. treating unread
  # request body as already consumed, or vice versa), corrupting this request or the next one on
  # the connection.
  #
  # validate_usage_counter! is called unconditionally at the top of every callback, since a
  # stale conn is a bug no matter what the call ends up doing. advance_usage_counter is called
  # separately, only at the point a callback actually commits to returning a new adapter - some
  # callbacks (inform/3, upgrade/3, chunk/2) have paths that report failure without producing a
  # new conn, and Plug's documented behaviour in that case is for the caller to keep using the
  # same (still current) conn.
  defp validate_usage_counter!(%__MODULE__{usage_counter: {shared, local}}) do
    case :counters.get(shared, 1) do
      ^local ->
        :ok

      _stale ->
        raise """
        Stale conn passed to a Plug.Conn function.

        This conn is not the one most recently returned by read_body/2, send_resp/3, or another \
        Plug.Conn function that returns an updated conn. Every such function returns an updated \
        conn that must be threaded through to the rest of your pipeline - discarding it and \
        reusing an older conn will corrupt this connection, and potentially the next request on \
        it if the connection is kept alive.
        """
    end
  end

  defp advance_usage_counter(%__MODULE__{usage_counter: {shared, local}} = adapter) do
    :counters.add(shared, 1, 1)
    %{adapter | usage_counter: {shared, local + 1}}
  end
end
