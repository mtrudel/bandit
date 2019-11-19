defmodule Bandit.HTTP1Request do
  @type state :: :new | :headers_read | :no_body | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter
  @behaviour Bandit.HTTPRequest

  defstruct state: :new, socket: nil, buffer: <<>>, body_size: nil, body_encoding: nil, connection: nil, version: nil

  alias ThousandIsland.Socket

  @impl Bandit.HTTPRequest
  def request(%Socket{} = socket), do: {:ok, __MODULE__, %__MODULE__{socket: socket}}

  @impl Bandit.HTTPRequest
  def read_headers(req) do
    case do_read_headers(req) do
      {:ok, headers, method, path, %__MODULE__{buffer: buffer} = req} ->
        body_size = get_header(headers, "content-length")
        body_encoding = get_header(headers, "content-encoding")
        connection = get_header(headers, "connection")

        case {body_size, body_encoding} do
          {nil, nil} ->
            {:ok, headers, method, path, %{req | state: :no_body, connection: connection}}

          {body_size, nil} ->
            {:ok, headers, method, path,
             %{
               req
               | state: :headers_read,
                 body_size: String.to_integer(body_size) - byte_size(buffer),
                 connection: connection
             }}

          {_, body_encoding} ->
            {:ok, headers, method, path,
             %{req | state: :headers_read, body_encoding: body_encoding, connection: connection}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{state: :new}, _opts), do: raise(Bandit.HTTPRequest.UnreadHeadersError)
  def read_req_body(%__MODULE__{state: :no_body} = req, _opts), do: {:ok, nil, req}

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

  def read_req_body(%__MODULE__{state: :headers_read, buffer: buffer, body_encoding: "chunked"} = req, opts) do
    case do_read_chunk(req, opts) do
      # TODO

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read_chunk(%__MODULE__{socket: socket, buffer: buffer}, opts) do
    case :binary.match(buffer, "\r\n") do
      {offset, _} ->
        # TODO handle chunk size of zero here
        <<chunk_size_hex::binary-size(offset - 1), "\r\n", rest::binary>> = buffer
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<chunk::binary-size(chunk_size), rest::binary>> ->
            {:more, chunk, %{req | buffer: rest}}

          _ ->
            nil
            # TODO read more body & try again
        end

      :nomatch ->
        nil
        # TODO read more body & try again
    end
  end

  def read_req_body(%__MODULE__{state: :headers_read, body_encoding: "chunked"} = req, opts)
      when not is_nil(body_encoding) do
    raise(Bandit.HTTPRequest.UnsupportedTransferEncodingError)
  end

  def read_req_body(%__MODULE__{}, _opts), do: raise(Bandit.HTTPRequest.AlreadyReadError)

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{state: :sent}, _, _, _), do: raise(Bandit.HTTPRequest.AlreadySentError)
  def send_resp(%__MODULE__{state: :chunking_out}, _, _, _), do: raise(Bandit.HTTPRequest.AlreadySentError)

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    # TODO refactor and add error handling
    resp = [to_string(version), " ", to_string(status), "\r\n", format_headers(headers, response), "\r\n", response]
    Socket.send(socket, resp)

    {:ok, nil, %{req | state: :sent}}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{} = req, _status, _headers, _path, _offset, _length) do
    # TODO
    {:ok, nil, %{req | state: :sent}}
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = req, _status, _headers) do
    # TODO
    {:ok, nil, %{req | state: :chunking_out}}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = req, _chunk) do
    # TODO
    {:ok, nil, req}
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers) do
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers) do
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{socket: socket}) do
    Socket.peer_info(socket)
  end

  @impl Bandit.HTTPRequest
  def get_local_data(%__MODULE__{socket: socket}) do
    Socket.local_info(socket)
  end

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{version: version}), do: version

  @impl Bandit.HTTPRequest
  def keepalive?(%__MODULE__{version: version}), do: version == :"HTTP/1.1"

  defp do_read_headers(req, type \\ :http, headers \\ [], method \\ nil, path \\ nil)

  defp do_read_headers(%__MODULE__{buffer: buffer} = req, type, headers, method, path) do
    case :erlang.decode_packet(type, buffer, []) do
      {:more, _len} ->
        case grow_buffer(req, :all_available) do
          {:ok, req} -> do_read_headers(req, type, headers, method, path)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:http_request, method, {:abs_path, path}, version}, rest} ->
        do_read_headers(%{req | buffer: rest, version: version(version)}, :httph, headers, method, path)

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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read_headers(%__MODULE__{}, _, _, _, _), do: raise(Bandit.HTTPRequest.AlreadyReadError)

  defp get_header(headers, header, default \\ nil) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> default
    end
  end

  defp format_headers(headers, body) do
    [{"content-length", body |> byte_size() |> to_string()} | headers]
    |> Enum.flat_map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
  end

  defp version({1, 1}), do: :"HTTP/1.1"
  defp version({1, 0}), do: :"HTTP/1.0"

  defp grow_buffer(req, to_read, opts \\ [])
  defp grow_buffer(%__MODULE__{} = req, 0, _opts), do: {:ok, req}

  defp grow_buffer(%__MODULE__{socket: socket, buffer: buffer} = req, to_read, opts) do
    to_read = if to_read == :all_available, do: 0, else: to_read
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
end
