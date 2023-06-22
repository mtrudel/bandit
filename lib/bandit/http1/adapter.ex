defmodule Bandit.HTTP1.Adapter do
  @moduledoc false

  @type state :: :new | :headers_read | :no_body | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter

  defstruct state: :new,
            transport_info: nil,
            socket: nil,
            buffer: <<>>,
            body_remaining: nil,
            body_encoding: nil,
            version: nil,
            keepalive: false,
            content_encoding: nil,
            upgrade: nil,
            metrics: %{},
            websocket_enabled: false,
            opts: []

  @typedoc "A struct for backing a Plug.Conn.Adapter"
  @type t :: %__MODULE__{
          state: state(),
          transport_info: Bandit.TransportInfo.t(),
          socket: ThousandIsland.Socket.t(),
          buffer: binary(),
          body_remaining: nil | integer(),
          body_encoding: nil | binary(),
          version: nil | :"HTTP/1.1" | :"HTTP/1.0",
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

  def read_headers(req) do
    with {:ok, headers, method, request_target, %__MODULE__{} = req} <- do_read_headers(req),
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
          {:ok, headers, method, request_target, %{req | state: :no_body}}

        {body_size, nil} ->
          body_remaining = body_size - byte_size(req.buffer)

          {:ok, headers, method, request_target,
           %{req | state: :headers_read, body_remaining: body_remaining}}

        {nil, body_encoding} ->
          {:ok, headers, method, request_target,
           %{req | state: :headers_read, body_encoding: body_encoding}}

        {_content_length, _body_encoding} ->
          {:error,
           "request cannot contain 'content-length' and 'transfer-encoding' (RFC9112§6.3.3)"}
      end
    end
  end

  @dialyzer {:no_improper_lists, do_read_headers: 5}
  defp do_read_headers(
         req,
         type \\ :http_bin,
         headers \\ [],
         method \\ nil,
         request_target \\ nil
       ) do
    # Figure out how to limit this read based on if we're reading request line or headers
    packet_size =
      case method do
        nil -> Keyword.get(req.opts.http_1, :max_request_line_length, 10_000)
        _ -> Keyword.get(req.opts.http_1, :max_header_length, 10_000)
      end

    case :erlang.decode_packet(type, req.buffer, packet_size: packet_size) do
      {:more, _len} ->
        with {:ok, chunk} <- read_available(req.socket, _read_timeout = nil) do
          req = %{req | buffer: req.buffer <> chunk}
          do_read_headers(req, type, headers, method, request_target)
        end

      {:ok, {:http_request, method, request_target, version}, rest} ->
        with {:ok, version} <- get_version(version),
             {:ok, request_target} <- resolve_request_target(request_target) do
          bytes_read = byte_size(req.buffer) - byte_size(rest)
          metrics = Map.update(req.metrics, :req_line_bytes, bytes_read, &(&1 + bytes_read))
          req = %{req | buffer: rest, version: version, metrics: metrics}
          do_read_headers(req, :httph_bin, headers, method, request_target)
        end

      {:ok, {:http_header, _, header, _, value}, rest} ->
        bytes_read = byte_size(req.buffer) - byte_size(rest)
        metrics = Map.update(req.metrics, :req_header_bytes, bytes_read, &(&1 + bytes_read))
        req = %{req | buffer: rest, metrics: metrics}
        headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]

        if length(headers) <= Keyword.get(req.opts.http_1, :max_header_count, 50) do
          do_read_headers(req, :httph_bin, headers, to_string(method), request_target)
        else
          {:error, :too_many_headers}
        end

      {:ok, :http_eoh, rest} ->
        bytes_read = byte_size(req.buffer) - byte_size(rest)

        metrics =
          req.metrics
          |> Map.update(:req_header_bytes, bytes_read, &(&1 + bytes_read))
          |> Map.put(:req_header_end_time, Bandit.Telemetry.monotonic_time())

        req = %{req | state: :headers_read, buffer: rest, metrics: metrics}
        {:ok, headers, method, request_target, req}

      {:ok, {:http_error, reason}, _rest} ->
        {:error, "header read error: #{inspect(reason)}"}

      {:error, :invalid} ->
        case method do
          nil -> {:error, :request_uri_too_long}
          _ -> {:error, :header_too_long}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `close` & `keep-alive` always means what they say, otherwise keepalive if we're on HTTP/1.1
  defp should_keepalive?(_, "close"), do: false
  defp should_keepalive?(_, "keep-alive"), do: true
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
  def read_req_body(%__MODULE__{state: :no_body} = req, _opts) do
    time = Bandit.Telemetry.monotonic_time()

    metrics =
      req.metrics
      |> Map.put(:req_body_bytes, 0)
      |> Map.put(:req_body_start_time, time)
      |> Map.put(:req_body_end_time, time)

    {:ok, <<>>, %{req | metrics: metrics}}
  end

  def read_req_body(
        %__MODULE__{state: :headers_read, buffer: buffer, body_remaining: 0} = req,
        _opts
      ) do
    time = Bandit.Telemetry.monotonic_time()

    metrics =
      req.metrics
      |> Map.update(:req_body_bytes, byte_size(buffer), &(&1 + byte_size(buffer)))
      |> Map.put_new(:req_body_start_time, time)
      |> Map.put(:req_body_end_time, time)

    {:ok, buffer, %{req | state: :body_read, buffer: <<>>, metrics: metrics}}
  end

  def read_req_body(
        %__MODULE__{state: :headers_read, body_remaining: body_remaining, buffer: buffer} = req,
        opts
      )
      when is_number(body_remaining) do
    max_desired_bytes = Keyword.get(opts, :length, 8_000_000)
    read_size = Keyword.get(opts, :read_length, 1_000_000)
    read_timeout = Keyword.get(opts, :read_timeout)

    if byte_size(buffer) >= max_desired_bytes do
      <<to_return::binary-size(max_desired_bytes), rest::binary>> = buffer

      metrics =
        req.metrics
        |> Map.update(:req_body_bytes, byte_size(to_return), &(&1 + byte_size(to_return)))
        |> Map.put_new_lazy(:req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

      {:more, to_return, %{req | buffer: rest, metrics: metrics}}
    else
      metrics =
        Map.put_new_lazy(req.metrics, :req_body_start_time, &Bandit.Telemetry.monotonic_time/0)

      to_read = min(body_remaining, max_desired_bytes - byte_size(buffer))

      with {:ok, iolist} <- read(req.socket, to_read, [], read_size, read_timeout) do
        result = IO.iodata_to_binary([buffer | iolist])
        result_size = byte_size(result)
        body_remaining = body_remaining - result_size

        if body_remaining > 0 do
          metrics = Map.update(metrics, :req_body_bytes, result_size, &(&1 + result_size))

          {:more, result, %{req | buffer: <<>>, body_remaining: body_remaining, metrics: metrics}}
        else
          metrics =
            metrics
            |> Map.update(:req_body_bytes, byte_size(result), &(&1 + byte_size(result)))
            |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

          {:ok, result,
           %{req | state: :body_read, buffer: <<>>, body_remaining: 0, metrics: metrics}}
        end
      end
    end
  end

  def read_req_body(
        %__MODULE__{
          state: :headers_read,
          body_encoding: "chunked",
          socket: socket,
          buffer: buffer
        } = req,
        opts
      ) do
    start_time = Bandit.Telemetry.monotonic_time()
    read_size = Keyword.get(opts, :read_length, 1_000_000)
    read_timeout = Keyword.get(opts, :read_timeout)

    with {:ok, body, buffer} <- do_read_chunk(socket, buffer, <<>>, read_size, read_timeout) do
      body = IO.iodata_to_binary(body)

      metrics =
        req.metrics
        |> Map.put(:req_body_bytes, byte_size(body))
        |> Map.put(:req_body_start_time, start_time)
        |> Map.put(:req_body_end_time, Bandit.Telemetry.monotonic_time())

      {:ok, body, %{req | buffer: buffer, metrics: metrics}}
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: body_encoding}, _opts)
      when not is_nil(body_encoding) do
    {:error, :unsupported_transfer_encoding}
  end

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  @dialyzer {:no_improper_lists, do_read_chunk: 5}
  defp do_read_chunk(socket, buffer, body, read_size, read_timeout) do
    case :binary.split(buffer, "\r\n") do
      ["0", _] ->
        {:ok, IO.iodata_to_binary(body), buffer}

      [chunk_size, rest] ->
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
            do_read_chunk(socket, rest, [body, next_chunk], read_size, read_timeout)

          _ ->
            to_read = chunk_size - byte_size(rest)

            if to_read > 0 do
              with {:ok, iolist} <- read(socket, to_read, [], read_size, read_timeout) do
                buffer = IO.iodata_to_binary([buffer | iolist])
                do_read_chunk(socket, buffer, body, read_size, read_timeout)
              end
            else
              with {:ok, chunk} <- read_available(socket, read_timeout) do
                buffer = buffer <> chunk
                do_read_chunk(socket, buffer, body, read_size, read_timeout)
              end
            end
        end

      _ ->
        with {:ok, chunk} <- read_available(socket, read_timeout) do
          buffer = buffer <> chunk
          do_read_chunk(socket, buffer, body, read_size, read_timeout)
        end
    end
  end

  ##################
  # Internal Reading
  ##################

  @compile {:inline, read_available: 2}
  @spec read_available(ThousandIsland.Socket.t(), timeout()) ::
          {:ok, binary()} | {:error, :closed | :timeout | :inet.posix()}
  defp read_available(socket, read_timeout) do
    ThousandIsland.Socket.recv(socket, 0, read_timeout)
  end

  @dialyzer {:no_improper_lists, read: 5}
  @spec read(
          ThousandIsland.Socket.t(),
          non_neg_integer(),
          iolist(),
          non_neg_integer(),
          timeout()
        ) :: {:ok, iolist()} | {:error, :closed | :timeout | :inet.posix()}
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
  def send_resp(%__MODULE__{state: :sent}, _, _, _), do: raise(Plug.Conn.AlreadySentError)
  def send_resp(%__MODULE__{state: :chunking_out}, _, _, _), do: raise(Plug.Conn.AlreadySentError)

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, body) do
    start_time = Bandit.Telemetry.monotonic_time()
    response_content_encoding_header = Bandit.Headers.get_header(headers, "content-encoding")

    {body, headers, compression_metrics} =
      case {body, req.content_encoding, response_content_encoding_header} do
        {body, content_encoding, nil} when body != <<>> and not is_nil(content_encoding) ->
          metrics = %{
            resp_uncompressed_body_bytes: IO.iodata_length(body),
            resp_compression_method: content_encoding
          }

          deflate_options = Keyword.get(req.opts.http_1, :deflate_options, [])
          deflated_body = Bandit.Compression.compress(body, req.content_encoding, deflate_options)
          headers = [{"content-encoding", req.content_encoding} | headers]
          {deflated_body, headers, metrics}

        _ ->
          {body, headers, %{}}
      end

    body_bytes = IO.iodata_length(body)
    headers = Bandit.Headers.add_content_length(headers, body_bytes, status)

    {header_iodata, header_metrics} = response_header(version, status, headers)
    _ = ThousandIsland.Socket.send(socket, [header_iodata, body])

    metrics =
      req.metrics
      |> Map.merge(compression_metrics)
      |> Map.merge(header_metrics)
      |> Map.put(:resp_body_bytes, body_bytes)
      |> Map.put(:resp_start_time, start_time)
      |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

    {:ok, nil, %{req | state: :sent, metrics: metrics}}
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
      headers = [{"content-length", length |> to_string()} | headers]
      {header_iodata, header_metrics} = response_header(version, status, headers)
      _ = ThousandIsland.Socket.send(socket, header_iodata)
      _ = ThousandIsland.Socket.sendfile(socket, path, offset, length)

      metrics =
        req.metrics
        |> Map.merge(header_metrics)
        |> Map.put(:resp_body_bytes, length)
        |> Map.put(:resp_start_time, start_time)
        |> Map.put(:resp_end_time, Bandit.Telemetry.monotonic_time())

      {:ok, nil, %{req | state: :sent, metrics: metrics}}
    else
      {:error,
       "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{socket: socket, version: version} = req, status, headers) do
    start_time = Bandit.Telemetry.monotonic_time()

    headers = [{"transfer-encoding", "chunked"} | headers]
    {header_iodata, header_metrics} = response_header(version, status, headers)
    _ = ThousandIsland.Socket.send(socket, header_iodata)

    metrics =
      req.metrics
      |> Map.merge(header_metrics)
      |> Map.put(:resp_start_time, start_time)
      |> Map.put(:resp_body_bytes, 0)

    {:ok, nil, %{req | state: :chunking_out, metrics: metrics}}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{socket: socket}, chunk) do
    byte_size = chunk |> IO.iodata_length() |> Integer.to_string(16)
    _ = ThousandIsland.Socket.send(socket, [byte_size, "\r\n", chunk, "\r\n"])
    :ok
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

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers), do: {:error, :not_supported}

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
