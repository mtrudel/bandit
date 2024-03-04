defmodule Bandit.HTTP1.Adapter do
  @moduledoc false

  @type read_state :: :unread | :headers_read | :no_body | :body_read
  @type write_state :: :unwritten | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter

  defstruct read_state: :unread,
            write_state: :unwritten,
            transport_info: nil,
            socket: nil,
            buffer: <<>>,
            body_remaining: nil,
            body_encoding: nil,
            version: nil,
            method: nil,
            keepalive: false,
            content_encoding: nil,
            upgrade: nil,
            metrics: %{},
            websocket_enabled: false,
            opts: []

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          read_state: read_state(),
          write_state: write_state(),
          transport_info: Bandit.TransportInfo.t(),
          socket: ThousandIsland.Socket.t(),
          buffer: binary(),
          body_remaining: nil | integer(),
          body_encoding: nil | binary(),
          version: nil | :"HTTP/1.1" | :"HTTP/1.0",
          method: Plug.Conn.method() | nil,
          keepalive: boolean(),
          content_encoding: String.t(),
          upgrade: nil | {:websocket, opts :: keyword(), websocket_opts :: keyword()},
          metrics: %{},
          websocket_enabled: boolean(),
          opts: %{
            required(:http_1) => Bandit.http_1_options(),
            required(:websocket) => Bandit.websocket_options()
          }
        }

  ################
  # Header Reading
  ################

  def read_request_line(req, request_target \\ nil) do
    packet_size = Keyword.get(req.opts.http_1, :max_request_line_length, 10_000)

    case :erlang.decode_packet(:http_bin, req.buffer, packet_size: packet_size) do
      {:more, _len} ->
        with {:ok, chunk} <- read_available(req.socket, _read_timeout = nil) do
          read_request_line(%{req | buffer: req.buffer <> chunk}, request_target)
        end

      {:ok, {:http_request, method, request_target, version}, rest} ->
        with {:ok, version} <- get_version(version),
             {:ok, request_target} <- resolve_request_target(request_target) do
          method = to_string(method)
          bytes_read = byte_size(req.buffer) - byte_size(rest)
          metrics = Map.update(req.metrics, :req_line_bytes, bytes_read, &(&1 + bytes_read))
          req = %{req | buffer: rest, version: version, method: method, metrics: metrics}
          {:ok, request_target, req}
        end

      {:ok, {:http_error, reason}, _rest} ->
        {:error, "request line read error: #{inspect(reason)}"}

      {:error, :invalid} ->
        {:error, :request_uri_too_long}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_headers(req) do
    with {:ok, headers, %__MODULE__{} = req} <- do_read_headers(req),
         {:ok, body_size} <- Bandit.Headers.get_content_length(headers) do
      body_encoding = Bandit.Headers.get_header(headers, "transfer-encoding")

      content_encoding =
        Bandit.Compression.negotiate_content_encoding(
          Bandit.Headers.get_header(headers, "accept-encoding"),
          Keyword.get(req.opts.http_1, :compress, true)
        )

      connection = Bandit.Headers.get_header(headers, "connection")
      keepalive = should_keepalive?(req.version, connection)
      req = %{req | content_encoding: content_encoding, keepalive: keepalive}

      case {body_size, body_encoding} do
        {nil, nil} ->
          {:ok, headers, %{req | read_state: :no_body}}

        {body_size, nil} ->
          body_remaining = body_size - byte_size(req.buffer)

          {:ok, headers, %{req | read_state: :headers_read, body_remaining: body_remaining}}

        {nil, body_encoding} ->
          {:ok, headers, %{req | read_state: :headers_read, body_encoding: body_encoding}}

        {_content_length, _body_encoding} ->
          {:error,
           "request cannot contain 'content-length' and 'transfer-encoding' (RFC9112§6.3.3)"}
      end
    end
  end

  defp do_read_headers(req, headers \\ []) do
    packet_size = Keyword.get(req.opts.http_1, :max_header_length, 10_000)

    case :erlang.decode_packet(:httph_bin, req.buffer, packet_size: packet_size) do
      {:more, _len} ->
        with {:ok, chunk} <- read_available(req.socket, _read_timeout = nil) do
          req = %{req | buffer: req.buffer <> chunk}
          do_read_headers(req, headers)
        end

      {:ok, {:http_header, _, header, _, value}, rest} ->
        bytes_read = byte_size(req.buffer) - byte_size(rest)
        metrics = Map.update(req.metrics, :req_header_bytes, bytes_read, &(&1 + bytes_read))
        req = %{req | buffer: rest, metrics: metrics}
        headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]

        if length(headers) <= Keyword.get(req.opts.http_1, :max_header_count, 50) do
          do_read_headers(req, headers)
        else
          {:error, :too_many_headers}
        end

      {:ok, :http_eoh, rest} ->
        bytes_read = byte_size(req.buffer) - byte_size(rest)

        metrics =
          req.metrics
          |> Map.update(:req_header_bytes, bytes_read, &(&1 + bytes_read))
          |> Map.put(:req_header_end_time, Bandit.Telemetry.monotonic_time())

        req = %{req | read_state: :headers_read, buffer: rest, metrics: metrics}
        {:ok, headers, req}

      {:ok, {:http_error, reason}, _rest} ->
        {:error, "header read error: #{inspect(reason)}"}

      {:error, :invalid} ->
        {:error, :header_too_long}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `close` & `keep-alive` always means what they say, otherwise keepalive if we're on HTTP/1.1
  # Case insensitivity per RFC9110§7.6.1
  defp should_keepalive?(_, "close"), do: false
  defp should_keepalive?(_, "keep-alive"), do: true
  defp should_keepalive?(_, "Keep-Alive"), do: true
  defp should_keepalive?(:"HTTP/1.1", _), do: true
  defp should_keepalive?(_, _), do: false

  defp get_version({1, 1}), do: {:ok, :"HTTP/1.1"}
  defp get_version({1, 0}), do: {:ok, :"HTTP/1.0"}
  defp get_version(other), do: {:error, "invalid HTTP version: #{inspect(other)}"}

  # Unwrap different request_targets returned by :erlang.decode_packet/3
  defp resolve_request_target({:abs_path, path}), do: {:ok, {nil, nil, nil, path}}

  defp resolve_request_target({:absoluteURI, scheme, host, :undefined, path}),
    do: {:ok, {to_string(scheme), host, nil, path}}

  defp resolve_request_target({:absoluteURI, scheme, host, port, path}),
    do: {:ok, {to_string(scheme), host, port, path}}

  defp resolve_request_target(:*), do: {:ok, {nil, nil, nil, :*}}

  defp resolve_request_target({:scheme, _scheme, _path}),
    do: {:error, "schemeURI is not supported"}

  defp resolve_request_target(_request_target),
    do: {:error, "Unsupported request target (RFC9112§3.2)"}

  ##############
  # Body Reading
  ##############

  @dialyzer {:no_improper_lists, read_req_body: 2}
  @impl Plug.Conn.Adapter
  @spec read_req_body(t(), keyword()) ::
          {:ok, data :: binary(), t()} | {:more, data :: binary(), t()} | {:error, term()}
  def read_req_body(%__MODULE__{read_state: :no_body} = req, _opts) do
    time = Bandit.Telemetry.monotonic_time()

    metrics =
      req.metrics
      |> Map.put(:req_body_bytes, 0)
      |> Map.put(:req_body_start_time, time)
      |> Map.put(:req_body_end_time, time)

    {:ok, <<>>, %{req | metrics: metrics}}
  end

  def read_req_body(
        %__MODULE__{read_state: :headers_read, body_remaining: body_remaining} = req,
        opts
      )
      when is_number(body_remaining) do
    metrics =
      Map.put_new_lazy(req.metrics, :req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

    with {:ok, to_return, buffer, body_remaining} <-
           do_read_content_length_body(req.socket, req.buffer, body_remaining, opts) do
      if byte_size(buffer) == 0 && body_remaining == 0 do
        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(to_return), &(&1 + byte_size(to_return)))
          |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

        {:ok, to_return,
         %{req | read_state: :body_read, buffer: <<>>, body_remaining: 0, metrics: metrics}}
      else
        metrics =
          metrics
          |> Map.update(:req_body_bytes, byte_size(to_return), &(&1 + byte_size(to_return)))

        {:more, to_return,
         %{req | buffer: buffer, body_remaining: body_remaining, metrics: metrics}}
      end
    end
  end

  def read_req_body(%__MODULE__{read_state: :headers_read, body_encoding: "chunked"} = req, opts) do
    metrics =
      Map.put_new_lazy(req.metrics, :req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

    read_size = Keyword.get(opts, :read_length, 1_000_000)
    read_timeout = Keyword.get(opts, :read_timeout)

    with {:ok, body, buffer} <-
           do_read_chunked_body(req.socket, req.buffer, <<>>, read_size, read_timeout) do
      body = IO.iodata_to_binary(body)

      metrics =
        metrics
        |> Map.put(:req_body_bytes, byte_size(body))
        |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

      {:ok, body, %{req | read_state: :body_read, buffer: buffer, metrics: metrics}}
    end
  end

  def read_req_body(%__MODULE__{read_state: :headers_read, body_encoding: body_encoding}, _opts)
      when not is_nil(body_encoding) do
    {:error, :unsupported_transfer_encoding}
  end

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  @dialyzer {:no_improper_lists, do_read_content_length_body: 4}
  defp do_read_content_length_body(socket, buffer, body_remaining, opts) do
    max_desired_bytes = Keyword.get(opts, :length, 8_000_000)

    cond do
      body_remaining < 0 ->
        # We have read more bytes than content-length suggested should have been sent. This is
        # veering into request smuggling territory and should never happen with a well behaved
        # client. The safest thing to do is just error
        {:error, :excess_body_read}

      byte_size(buffer) >= max_desired_bytes || body_remaining == 0 ->
        # We can satisfy the read request entirely from our buffer
        bytes_to_return = min(max_desired_bytes, byte_size(buffer))
        <<to_return::binary-size(bytes_to_return), rest::binary>> = buffer
        {:ok, to_return, rest, body_remaining}

      true ->
        # We need to read off the wire
        bytes_to_read = min(max_desired_bytes - byte_size(buffer), body_remaining)
        read_size = Keyword.get(opts, :read_length, 1_000_000)
        read_timeout = Keyword.get(opts, :read_timeout)

        with {:ok, iolist} <- read(socket, bytes_to_read, [], read_size, read_timeout) do
          to_return = IO.iodata_to_binary([buffer | iolist])
          body_remaining = body_remaining - (byte_size(to_return) - byte_size(buffer))
          {:ok, to_return, <<>>, body_remaining}
        end
    end
  end

  @dialyzer {:no_improper_lists, do_read_chunked_body: 5}
  defp do_read_chunked_body(socket, buffer, body, read_size, read_timeout) do
    case :binary.split(buffer, "\r\n") do
      ["0", _] ->
        {:ok, IO.iodata_to_binary(body), buffer}

      [chunk_size, rest] ->
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
            do_read_chunked_body(socket, rest, [body, next_chunk], read_size, read_timeout)

          _ ->
            to_read = chunk_size - byte_size(rest)

            if to_read > 0 do
              with {:ok, iolist} <- read(socket, to_read, [], read_size, read_timeout) do
                buffer = IO.iodata_to_binary([buffer | iolist])
                do_read_chunked_body(socket, buffer, body, read_size, read_timeout)
              end
            else
              with {:ok, chunk} <- read_available(socket, read_timeout) do
                buffer = buffer <> chunk
                do_read_chunked_body(socket, buffer, body, read_size, read_timeout)
              end
            end
        end

      _ ->
        with {:ok, chunk} <- read_available(socket, read_timeout) do
          buffer = buffer <> chunk
          do_read_chunked_body(socket, buffer, body, read_size, read_timeout)
        end
    end
  end

  ##################
  # Internal Reading
  ##################

  @compile {:inline, read_available: 2}
  @spec read_available(ThousandIsland.Socket.t(), timeout() | nil) ::
          {:ok, binary()} | {:error, :closed | :timeout | :inet.posix()}
  defp read_available(socket, read_timeout) do
    ThousandIsland.Socket.recv(socket, 0, read_timeout)
  end

  @dialyzer {:no_improper_lists, read: 5}
  @spec read(ThousandIsland.Socket.t(), non_neg_integer(), iolist(), non_neg_integer(), timeout()) ::
          {:ok, iolist()} | {:error, :closed | :timeout | :inet.posix()}
  defp read(socket, to_read, already_read, read_size, read_timeout) do
    with {:ok, chunk} <- ThousandIsland.Socket.recv(socket, min(to_read, read_size), read_timeout) do
      remaining_bytes = to_read - byte_size(chunk)

      if remaining_bytes > 0 do
        read(socket, remaining_bytes, [already_read | chunk], read_size, read_timeout)
      else
        {:ok, [already_read | chunk]}
      end
    end
  end

  ##################
  # Response Sending
  ##################

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{write_state: :sent}, _, _, _), do: raise(Plug.Conn.AlreadySentError)

  def send_resp(%__MODULE__{write_state: :chunking_out}, _, _, _),
    do: raise(Plug.Conn.AlreadySentError)

  def send_resp(%__MODULE__{} = req, status, headers, body) do
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
      case {body, req.content_encoding, response_content_encoding_header,
            response_has_strong_etag, response_indicates_no_transform} do
        {body, content_encoding, nil, false, false}
        when raw_body_bytes > 0 and not is_nil(content_encoding) ->
          metrics = %{
            resp_uncompressed_body_bytes: raw_body_bytes,
            resp_compression_method: content_encoding
          }

          deflate_options = Keyword.get(req.opts.http_1, :deflate_options, [])
          deflated_body = Bandit.Compression.compress(body, req.content_encoding, deflate_options)
          headers = [{"content-encoding", req.content_encoding} | headers]
          {deflated_body, headers, metrics}

        _ ->
          {body, headers, %{}}
      end

    compress = Keyword.get(req.opts.http_1, :compress, true)
    headers = if compress, do: [{"vary", "accept-encoding"} | headers], else: headers
    body_bytes = IO.iodata_length(body)
    headers = Bandit.Headers.add_content_length(headers, body_bytes, status)

    {header_iodata, header_metrics} = response_header(req.version, status, headers)

    {body_iodata, body_metrics} =
      if send_resp_body?(req, status) do
        {body, %{resp_body_bytes: body_bytes}}
      else
        {[], %{resp_body_bytes: 0}}
      end

    _ = ThousandIsland.Socket.send(req.socket, [header_iodata | body_iodata])

    metrics =
      req.metrics
      |> Map.merge(compression_metrics)
      |> Map.merge(header_metrics)
      |> Map.merge(body_metrics)
      |> Map.put(:resp_start_time, start_time)
      |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

    {:ok, nil, %{req | write_state: :sent, metrics: metrics}}
  end

  @impl Plug.Conn.Adapter
  def send_file(
        %__MODULE__{socket: socket, version: version} = req,
        status,
        headers,
        path,
        offset,
        length
      ) do
    start_time = Bandit.Telemetry.monotonic_time()
    %File.Stat{type: :regular, size: size} = File.stat!(path)

    length =
      cond do
        length == :all -> size - offset
        is_integer(length) -> length
      end

    if offset + length <= size do
      headers = Bandit.Headers.add_content_length(headers, length, status)
      {header_iodata, header_metrics} = response_header(version, status, headers)
      _ = ThousandIsland.Socket.send(socket, header_iodata)

      body_metrics =
        if send_resp_body?(req, status) do
          _ = ThousandIsland.Socket.sendfile(socket, path, offset, length)
          %{resp_body_bytes: length}
        else
          %{resp_body_bytes: 0}
        end

      metrics =
        req.metrics
        |> Map.merge(header_metrics)
        |> Map.merge(body_metrics)
        |> Map.put(:resp_start_time, start_time)
        |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

      {:ok, nil, %{req | write_state: :sent, metrics: metrics}}
    else
      {:error,
       "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{socket: socket, version: version} = req, status, headers) do
    start_time = Bandit.Telemetry.monotonic_time()

    headers =
      if status >= 200 and status != 204 do
        [{"transfer-encoding", "chunked"} | headers]
      else
        headers
      end

    {header_iodata, header_metrics} = response_header(version, status, headers)
    _ = ThousandIsland.Socket.send(socket, header_iodata)

    metrics =
      req.metrics
      |> Map.merge(header_metrics)
      |> Map.put(:resp_start_time, start_time)
      |> Map.put(:resp_body_bytes, 0)

    if send_resp_body?(req, status) do
      {:ok, nil, %{req | write_state: :chunking_out, metrics: metrics}}
    else
      {:ok, nil, %{req | write_state: :sent, metrics: metrics}}
    end
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{write_state: :chunking_out} = req, chunk) do
    byte_size = chunk |> IO.iodata_length()
    payload = [Integer.to_string(byte_size, 16), "\r\n", chunk, "\r\n"]

    case ThousandIsland.Socket.send(req.socket, payload) do
      :ok ->
        metrics = Map.update(req.metrics, :resp_body_bytes, byte_size, &(&1 + byte_size))

        metrics =
          if byte_size == 0 do
            Map.put(metrics, :resp_end_time, Bandit.Telemetry.monotonic_time())
          else
            metrics
          end

        {:ok, nil, %{req | metrics: metrics}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def chunk(_, _), do: :ok

  @impl Plug.Conn.Adapter
  def inform(%__MODULE__{version: :"HTTP/1.0"}, _status, _headers), do: {:error, :not_supported}

  def inform(%__MODULE__{socket: socket, version: version} = req, status, headers) do
    start_time = Bandit.Telemetry.monotonic_time()

    {header_iodata, header_metrics} = response_header(version, status, headers)
    _ = ThousandIsland.Socket.send(socket, header_iodata)

    metrics =
      req.metrics
      |> Map.merge(header_metrics)
      |> Map.put(:resp_start_time, start_time)
      |> Map.put(:resp_body_bytes, 0)

    {:ok, %{req | metrics: metrics}}
  end

  defp response_header(nil, status, headers), do: response_header("HTTP/1.0", status, headers)

  defp response_header(version, status, headers) do
    resp_line = [
      to_string(version),
      " ",
      to_string(status),
      " ",
      Plug.Conn.Status.reason_phrase(status),
      "\r\n"
    ]

    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end
      |> Enum.map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
      |> then(&[&1 | ["\r\n"]])

    metrics = %{
      resp_line_bytes: IO.iodata_length(resp_line),
      resp_header_bytes: IO.iodata_length(headers)
    }

    {[resp_line, headers], metrics}
  end

  defp send_resp_body?(%{method: "HEAD"}, _status), do: false
  defp send_resp_body?(_req, 204), do: false
  defp send_resp_body?(_req, 304), do: false
  defp send_resp_body?(_req, _status), do: true

  @impl Plug.Conn.Adapter
  def upgrade(%Bandit.HTTP1.Adapter{websocket_enabled: true} = req, :websocket, opts),
    do: {:ok, %{req | upgrade: {:websocket, opts, req.opts.websocket}}}

  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{transport_info: transport_info}),
    do: Bandit.TransportInfo.peer_data(transport_info)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{version: version}), do: version
end
