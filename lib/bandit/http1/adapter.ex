defmodule Bandit.HTTP1.Adapter do
  @moduledoc false

  @type state :: :new | :headers_read | :no_body | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter

  defstruct state: :new,
            socket: nil,
            buffer: <<>>,
            body_size: nil,
            body_encoding: nil,
            connection: nil,
            version: nil,
            keepalive: false

  alias ThousandIsland.Socket

  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.CondStatements
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  ################
  # Header Reading
  ################

  def read_headers(req) do
    case do_read_headers(req) do
      {:ok, headers, method, path, %__MODULE__{version: version, buffer: buffer} = req} ->
        body_size = get_header(headers, "content-length")
        body_encoding = get_header(headers, "transfer-encoding")
        connection = get_header(headers, "connection")
        keepalive = should_keepalive?(version, connection)

        case {body_size, body_encoding} do
          {nil, nil} ->
            {:ok, headers, method, path,
             %{req | state: :no_body, connection: connection, keepalive: keepalive}}

          {body_size, nil} ->
            {:ok, headers, method, path,
             %{
               req
               | state: :headers_read,
                 body_size: String.to_integer(body_size) - byte_size(buffer),
                 connection: connection,
                 keepalive: keepalive
             }}

          {_, body_encoding} ->
            {:ok, headers, method, path,
             %{
               req
               | state: :headers_read,
                 body_encoding: body_encoding,
                 connection: connection,
                 keepalive: keepalive
             }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read_headers(req, type \\ :http, headers \\ [], method \\ nil, path \\ nil)

  defp do_read_headers(%__MODULE__{buffer: buffer} = req, type, headers, method, path) do
    case :erlang.decode_packet(type, buffer, []) do
      {:more, _len} ->
        case grow_buffer(req, 0) do
          {:ok, req} -> do_read_headers(req, type, headers, method, path)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:http_request, method, {:abs_path, path}, version}, rest} ->
        version =
          case version do
            {1, 1} -> :"HTTP/1.1"
            {1, 0} -> :"HTTP/1.0"
          end

        do_read_headers(%{req | buffer: rest, version: version}, :httph, headers, method, path)

      {:ok, {:http_header, _, header, _, value}, rest} ->
        do_read_headers(
          %{req | buffer: rest},
          :httph,
          [{header |> to_string() |> String.downcase(:ascii), to_string(value)} | headers],
          to_string(method),
          to_string(path)
        )

      {:ok, :http_eoh, rest} ->
        {:ok, headers, method, path, %{req | state: :headers_read, buffer: rest}}

      {:ok, {:http_error, _reason}, _rest} ->
        {:error, :invalid_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # If we do not have a connection header, then keep alive iff we're running on HTTP/1.1
  defp should_keepalive?(version, nil), do: version == :"HTTP/1.1"

  defp should_keepalive?(version, connection_header) do
    case String.downcase(connection_header, :ascii) do
      "keep-alive" -> true
      "close" -> false
      _ -> version == :"HTTP/1.1"
    end
  end

  defp get_header(headers, header, default \\ nil) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> default
    end
  end

  ##############
  # Body Reading
  ##############

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{state: :no_body} = req, _opts), do: {:ok, <<>>, req}

  def read_req_body(%__MODULE__{state: :headers_read, buffer: buffer, body_size: 0} = req, _opts) do
    {:ok, buffer, %{req | state: :body_read, buffer: <<>>, body_size: 0}}
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_size: body_size} = req, opts)
      when is_number(body_size) do
    to_read = min(body_size, Keyword.get(opts, :length, 8_000_000))

    case grow_buffer(req, to_read, opts) do
      {:ok, %__MODULE__{buffer: buffer} = req} ->
        remaining_bytes = body_size - byte_size(buffer)

        if remaining_bytes > 0 do
          {:more, buffer, %{req | buffer: <<>>, body_size: remaining_bytes}}
        else
          {:ok, buffer, %{req | state: :body_read, buffer: <<>>, body_size: 0}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: "chunked"} = req, opts) do
    case do_read_chunk(req, <<>>, opts) do
      {:ok, body, req} -> {:ok, IO.iodata_to_binary(body), req}
      other -> other
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: body_encoding}, _opts)
      when not is_nil(body_encoding) do
    {:error, :unsupported_transfer_encoding}
  end

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.BodyAlreadyReadError)

  defp do_read_chunk(%__MODULE__{buffer: buffer} = req, body, opts) do
    case :binary.split(buffer, "\r\n") do
      ["0", _] ->
        {:ok, body, req}

      [chunk_size, rest] ->
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
            do_read_chunk(%{req | buffer: rest}, [body, next_chunk], opts)

          _ ->
            case grow_buffer(req, chunk_size - byte_size(rest), opts) do
              {:ok, req} -> do_read_chunk(req, body, opts)
              {:error, reason} -> {:error, reason}
            end
        end

      _ ->
        case grow_buffer(req, 0, opts) do
          {:ok, req} -> do_read_chunk(req, body, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  ##################
  # Internal Reading
  ##################

  defp grow_buffer(%__MODULE__{socket: socket, buffer: buffer} = req, to_read, opts \\ []) do
    read_size = min(to_read, Keyword.get(opts, :read_length, 1_000_000))
    read_timeout = Keyword.get(opts, :read_timeout)

    case Socket.recv(socket, read_size, read_timeout) do
      {:ok, chunk} ->
        remaining_bytes = to_read - byte_size(chunk)

        if remaining_bytes > 0 do
          grow_buffer(%{req | buffer: buffer <> chunk}, remaining_bytes, opts)
        else
          {:ok, %{req | buffer: buffer <> chunk}}
        end

      {:error, reason} ->
        {:error, reason}
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
    Socket.send(socket, [header_io_data, response])
    {:ok, nil, %{req | state: :sent}}
  end

  # Per RFC2616§4.{3,4}
  defp add_content_length?(204), do: false
  defp add_content_length?(status) when status in 300..399, do: false
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
      Socket.send(socket, response_header(version, status, headers))
      Socket.sendfile(socket, path, offset, length)

      {:ok, nil, %{req | state: :sent}}
    else
      {:error,
       "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{socket: socket, version: version} = req, status, headers) do
    headers = [{"transfer-encoding", "chunked"} | headers]
    Socket.send(socket, response_header(version, status, headers))
    {:ok, nil, %{req | state: :chunking_out}}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{socket: socket}, chunk) do
    byte_size = chunk |> byte_size() |> Integer.to_string(16)
    Socket.send(socket, [byte_size, "\r\n", chunk, "\r\n"])
    :ok
  end

  defp response_header(nil, status, headers), do: response_header("HTTP/1.0", status, headers)

  defp response_header(version, status, headers) do
    headers =
      if List.keymember?(headers, "date", 0) do
        headers
      else
        [Bandit.Clock.date_header() | headers]
      end

    [
      to_string(version),
      " ",
      to_string(status),
      " ",
      reason_for_status(status),
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def upgrade(_req, _upgrade, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{socket: socket}), do: Socket.peer_info(socket)

  def get_local_data(%__MODULE__{socket: socket}), do: Socket.local_info(socket)

  def secure?(%__MODULE__{socket: socket}), do: Socket.secure?(socket)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{version: version}), do: version

  def keepalive?(%__MODULE__{keepalive: keepalive}), do: keepalive

  response_reasons = %{
    100 => "Continue",
    101 => "Switching Protocols",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Time-out",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Large",
    415 => "Unsupported Media Type",
    416 => "Requested range not satisfiable",
    417 => "Expectation Failed",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Time-out",
    505 => "HTTP Version not supported"
  }

  for {code, reason} <- response_reasons do
    defp reason_for_status(unquote(code)), do: unquote(reason)
  end

  defp reason_for_status(_), do: "Unknown Status Code"
end
