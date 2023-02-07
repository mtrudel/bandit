defmodule Bandit.HTTP1.Adapter do
  @moduledoc false

  @type state :: :new | :headers_read | :no_body | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter

  defstruct state: :new,
            socket: nil,
            buffer: <<>>,
            body_remaining: nil,
            body_encoding: nil,
            version: nil,
            keepalive: false,
            upgrade: nil

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  ################
  # Header Reading
  ################

  def read_headers(req) do
    with {:ok, headers, method, request_target, %__MODULE__{} = req} <- do_read_headers(req),
         {:ok, body_size} <- Bandit.Headers.get_content_length(headers) do
      body_encoding = Bandit.Headers.get_header(headers, "transfer-encoding")
      connection = Bandit.Headers.get_header(headers, "connection")
      keepalive = should_keepalive?(req.version, connection)

      case {body_size, body_encoding} do
        {nil, nil} ->
          {:ok, headers, method, request_target, %{req | state: :no_body, keepalive: keepalive}}

        {body_size, nil} ->
          body_remaining = body_size - byte_size(req.buffer)

          {:ok, headers, method, request_target,
           %{req | state: :headers_read, body_remaining: body_remaining, keepalive: keepalive}}

        {nil, body_encoding} ->
          {:ok, headers, method, request_target,
           %{req | state: :headers_read, body_encoding: body_encoding, keepalive: keepalive}}

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
    case :erlang.decode_packet(type, req.buffer, []) do
      {:more, _len} ->
        with {:ok, iodata} <- read(req.socket, 0) do
          # decode_packet expects a binary, so convert it to one
          req = %{req | buffer: IO.iodata_to_binary([req.buffer | iodata])}
          do_read_headers(req, type, headers, method, request_target)
        end

      {:ok, {:http_request, method, request_target, version}, rest} ->
        with {:ok, version} <- get_version(version),
             {:ok, request_target} <- resolve_request_target(request_target),
             req <- %{req | buffer: rest, version: version} do
          do_read_headers(req, :httph_bin, headers, method, request_target)
        end

      {:ok, {:http_header, _, header, _, value}, rest} ->
        req = %{req | buffer: rest}
        headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]
        do_read_headers(req, :httph_bin, headers, to_string(method), request_target)

      {:ok, :http_eoh, rest} ->
        {:ok, headers, method, request_target, %{req | state: :headers_read, buffer: rest}}

      {:ok, {:http_error, reason}, _rest} ->
        {:error, "header read error: #{inspect(reason)}"}

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

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{state: :no_body} = req, _opts), do: {:ok, <<>>, req}

  def read_req_body(
        %__MODULE__{state: :headers_read, buffer: buffer, body_remaining: 0} = req,
        _opts
      ) do
    {:ok, buffer, %{req | state: :body_read, buffer: <<>>}}
  end

  @dialyzer {:no_improper_lists, read_req_body: 2}
  def read_req_body(
        %__MODULE__{state: :headers_read, body_remaining: body_remaining, buffer: buffer} = req,
        opts
      )
      when is_number(body_remaining) do
    max_desired_bytes = Keyword.get(opts, :length, 8_000_000)

    if byte_size(buffer) >= max_desired_bytes do
      <<to_return::binary-size(max_desired_bytes), rest::binary>> = buffer
      {:more, to_return, %{req | buffer: rest}}
    else
      to_read = min(body_remaining, max_desired_bytes - byte_size(buffer))

      with {:ok, iodata} <- read(req.socket, to_read, opts) do
        result = IO.iodata_to_binary([buffer | iodata])
        body_remaining = body_remaining - IO.iodata_length(iodata)

        if body_remaining > 0 do
          {:more, result, %{req | buffer: <<>>, body_remaining: body_remaining}}
        else
          {:ok, result, %{req | state: :body_read, buffer: <<>>, body_remaining: 0}}
        end
      end
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: "chunked"} = req, opts) do
    with {:ok, body, req} <- do_read_chunk(req, <<>>, opts) do
      {:ok, IO.iodata_to_binary(body), req}
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: body_encoding}, _opts)
      when not is_nil(body_encoding) do
    {:error, :unsupported_transfer_encoding}
  end

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  @dialyzer {:no_improper_lists, do_read_chunk: 3}
  defp do_read_chunk(%__MODULE__{buffer: buffer} = req, body, opts) do
    case :binary.split(buffer, "\r\n") do
      ["0", _] ->
        {:ok, IO.iodata_to_binary(body), req}

      [chunk_size, rest] ->
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
            do_read_chunk(%{req | buffer: rest}, [body, next_chunk], opts)

          _ ->
            with {:ok, iodata} <- read(req.socket, chunk_size - byte_size(rest), opts) do
              req = %{req | buffer: IO.iodata_to_binary([req.buffer | iodata])}
              do_read_chunk(req, body, opts)
            end
        end

      _ ->
        with {:ok, iodata} <- read(req.socket, 0, opts) do
          req = %{req | buffer: IO.iodata_to_binary([req.buffer | iodata])}
          do_read_chunk(req, body, opts)
        end
    end
  end

  ##################
  # Internal Reading
  ##################

  @dialyzer {:no_improper_lists, read: 5}
  defp read(socket, to_read, opts \\ [], bytes_read \\ 0, already_read \\ []) do
    read_size = min(to_read, Keyword.get(opts, :read_length, 1_000_000))
    read_timeout = Keyword.get(opts, :read_timeout)

    with {:ok, chunk} <- ThousandIsland.Socket.recv(socket, read_size, read_timeout) do
      remaining_bytes = to_read - byte_size(chunk)
      bytes_read = bytes_read + byte_size(chunk)

      if remaining_bytes > 0 do
        read(socket, remaining_bytes, opts, bytes_read, [already_read | chunk])
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

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    headers =
      if add_content_length?(status) do
        [{"content-length", response |> IO.iodata_length() |> to_string()} | headers]
      else
        headers
      end

    header_io_data = response_header(version, status, headers)
    ThousandIsland.Socket.send(socket, [header_io_data, response])
    {:ok, nil, %{req | state: :sent}}
  end

  # Per RFC2616§4.{3,4}
  defp add_content_length?(status) when status in 100..199, do: false
  defp add_content_length?(204), do: false
  defp add_content_length?(304), do: false
  defp add_content_length?(_), do: true

  @impl Plug.Conn.Adapter
  def send_file(
        %__MODULE__{socket: socket, version: version} = req,
        status,
        headers,
        path,
        offset,
        length
      ) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)

    length =
      cond do
        length == :all -> size - offset
        is_integer(length) -> length
      end

    if offset + length <= size do
      headers = [{"content-length", length |> to_string()} | headers]
      ThousandIsland.Socket.send(socket, response_header(version, status, headers))
      ThousandIsland.Socket.sendfile(socket, path, offset, length)

      {:ok, nil, %{req | state: :sent}}
    else
      {:error,
       "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{socket: socket, version: version} = req, status, headers) do
    headers = [{"transfer-encoding", "chunked"} | headers]
    ThousandIsland.Socket.send(socket, response_header(version, status, headers))
    {:ok, nil, %{req | state: :chunking_out}}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{socket: socket}, chunk) do
    byte_size = chunk |> IO.iodata_length() |> Integer.to_string(16)
    ThousandIsland.Socket.send(socket, [byte_size, "\r\n", chunk, "\r\n"])
    :ok
  end

  defp response_header(nil, status, headers), do: response_header("HTTP/1.0", status, headers)

  defp response_header(version, status, headers) do
    headers =
      if is_nil(Bandit.Headers.get_header(headers, "date")) do
        [Bandit.Clock.date_header() | headers]
      else
        headers
      end

    [
      to_string(version),
      " ",
      to_string(status),
      " ",
      Plug.Conn.Status.reason_phrase(status),
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def upgrade(req, :websocket, opts), do: {:ok, %{req | upgrade: {:websocket, opts}}}

  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{socket: socket}), do: ThousandIsland.Socket.peer_info(socket)

  def get_local_data(%__MODULE__{socket: socket}), do: ThousandIsland.Socket.local_info(socket)

  def secure?(%__MODULE__{socket: socket}), do: ThousandIsland.Socket.secure?(socket)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{version: version}), do: version

  def keepalive?(%__MODULE__{keepalive: keepalive}), do: keepalive
end
