defmodule Bandit.HTTP1Request do
  @type state :: :new | :headers_read | :body_read | :sent | :chunking_out

  @behaviour Plug.Conn.Adapter
  @behaviour Bandit.HTTPRequest

  defstruct state: :new,
            socket: nil,
            version: nil,
            method: nil,
            path: nil,
            read_buffer: <<>>

  defmodule UnreadHeadersError do
    defexception message: "Headers have not been read yet"
  end

  defmodule AlreadyReadError do
    defexception message: "Body has already been read"
  end

  defmodule AlreadySentError do
    defexception message: "Response has already been written (or is being chunked out)"
  end

  alias ThousandIsland.Socket

  @impl Bandit.HTTPRequest
  def request(%Socket{} = socket), do: {:ok, __MODULE__, %__MODULE__{socket: socket}}

  @impl Bandit.HTTPRequest
  def read_headers(req, type \\ :http, headers \\ [])

  def read_headers(%__MODULE__{state: :new, socket: socket, read_buffer: read_buffer} = req, type, headers) do
    case :erlang.decode_packet(type, read_buffer, []) do
      {:more, _len} ->
        case Socket.recv(socket) do
          {:ok, more_data} -> read_headers(%{req | read_buffer: read_buffer <> more_data}, type, headers)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:http_request, method, {:abs_path, path}, version}, rest} ->
        read_headers(%{req | read_buffer: rest, version: version(version), method: method, path: path}, :httph, headers)

      {:ok, {:http_header, _, header, _, value}, rest} ->
        read_headers(%{req | read_buffer: rest}, :httph, [{header, value} | headers])

      {:ok, :http_eoh, rest} ->
        {:ok, headers, %{req | state: :headers_read, read_buffer: rest}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_headers(%__MODULE__{}, _, _), do: raise(AlreadyReadError)

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{state: :headers_read} = req, _opts) do
    # TODO 
    {:ok, <<>>, %{req | state: :body_read}}
  end

  def read_req_body(%__MODULE__{state: :new}, _opts), do: raise(UnreadHeadersError)
  def read_req_body(%__MODULE__{}, _opts), do: raise(AlreadyReadError)

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{state: state}, _, _, _) when state in [:sent, :chunking_out],
    do: raise(AlreadySentError)

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    # TODO refactor and add error handling
    resp = [version, " ", to_string(status), "\r\n", format_headers(headers, response), "\r\n", response]
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
  def keepalive?(%__MODULE__{version: version}), do: version == "HTTP/1.1"

  defp format_headers(headers, body) do
    [{"content-length", body |> byte_size() |> to_string()} | headers]
    |> Enum.flat_map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
  end

  defp version({1, 1}), do: "HTTP/1.1"
  defp version({1, 0}), do: "HTTP/1.0"
end
