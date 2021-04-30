defmodule Bandit.HTTP1Request do
  @moduledoc false

  @type state :: :new | :headers_read | :no_body | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter
  @behaviour Bandit.HTTPRequest

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

  @impl Bandit.HTTPRequest
  def request(%Socket{} = socket, data), do: {:ok, __MODULE__, %__MODULE__{socket: socket, buffer: data}}

  ################
  # Header Reading
  ################

  @impl Bandit.HTTPRequest
  def read_headers(req) do
    case do_read_headers(req) do
      {:ok, headers, method, path, %__MODULE__{version: version, buffer: buffer} = req} ->
        body_size = get_header(headers, "content-length")
        body_encoding = get_header(headers, "transfer-encoding")
        connection = get_header(headers, "connection")
        keepalive = should_keepalive?(version, headers)

        case {body_size, body_encoding} do
          {nil, nil} ->
            {:ok, headers, method, path, %{req | state: :no_body, connection: connection, keepalive: keepalive}}

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
             %{req | state: :headers_read, body_encoding: body_encoding, connection: connection, keepalive: keepalive}}
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
          [{header |> to_string() |> String.downcase(), to_string(value)} | headers],
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

  defp do_read_headers(%__MODULE__{}, _, _, _, _), do: raise(Bandit.HTTPRequest.AlreadyReadError)

  defp should_keepalive?(version, headers) do
    cond do
      get_header(headers, "connection") |> is_nil -> version == :"HTTP/1.1"
      get_header(headers, "connection") |> String.match?(~r/^keep-alive$/i) -> true
      get_header(headers, "connection") |> String.match?(~r/^close$/i) -> false
      version == :"HTTP/1.1" -> true
      true -> false
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
  def read_req_body(%__MODULE__{state: :new}, _opts), do: raise(Bandit.HTTPRequest.UnreadHeadersError)
  def read_req_body(%__MODULE__{state: :no_body} = req, _opts), do: {:ok, nil, req}

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

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.HTTPRequest.AlreadyReadError)

  defp do_read_chunk(%__MODULE__{buffer: buffer} = req, body, opts) do
    case :binary.match(buffer, "\r\n") do
      {offset, _} ->
        <<chunk_size::binary-size(offset), ?\r, ?\n, rest::binary>> = buffer

        case String.to_integer(chunk_size, 16) do
          0 ->
            {:ok, body, req}

          chunk_size ->
            case rest do
              <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
                do_read_chunk(%{req | buffer: rest}, [body, next_chunk], opts)

              _ ->
                case grow_buffer(req, chunk_size - byte_size(rest), opts) do
                  {:ok, req} -> do_read_chunk(req, body, opts)
                  {:error, reason} -> {:error, reason}
                end
            end
        end

      :nomatch ->
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
    read_timeout = Keyword.get(opts, :read_timeout, 15_000)

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
  def send_resp(%__MODULE__{state: :sent}, _, _, _), do: raise(Bandit.HTTPRequest.AlreadySentError)
  def send_resp(%__MODULE__{state: :chunking_out}, _, _, _), do: raise(Bandit.HTTPRequest.AlreadySentError)

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    headers = [{"content-length", response |> byte_size() |> to_string()} | headers]
    header_io_data = response_header(version, status, headers)
    Socket.send(socket, [header_io_data, response])
    {:ok, nil, %{req | state: :sent}}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{socket: socket, version: version} = req, status, headers, path, offset, length) do
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
      {:error, "Cannot read #{length} bytes starting at #{offset} as #{path} is only #{size} octets in length"}
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

  defp response_header(version, status, headers) do
    [
      to_string(version),
      " ",
      to_string(status),
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]
  end

  ######
  # Misc
  ######

  @impl Bandit.HTTPRequest
  def send_fallback_resp(%__MODULE__{state: :sent} = req, _status), do: close(req)
  def send_fallback_resp(%__MODULE__{state: :chunking_out} = req, _status), do: close(req)

  def send_fallback_resp(%__MODULE__{socket: socket} = req, status) do
    Socket.send(socket, "HTTP/1.0 #{to_string(status)}\r\n\r\n")
    close(req)
  end

  @impl Bandit.HTTPRequest
  def close(%__MODULE__{socket: socket}) do
    Socket.shutdown(socket, :write)
    Socket.close(socket)
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{socket: socket}), do: Socket.peer_info(socket)

  @impl Bandit.HTTPRequest
  def get_local_data(%__MODULE__{socket: socket}), do: Socket.local_info(socket)

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{version: version}), do: version

  @impl Bandit.HTTPRequest
  def keepalive?(%__MODULE__{keepalive: keepalive}), do: keepalive
end
