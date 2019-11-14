defmodule Bandit.HTTP1Request do
  @type state :: :new | :headers_read | :body_read | :sent | :chunking_out

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

  alias Bandit.HTTP1Request
  alias ThousandIsland.Socket

  defimpl Bandit.HTTPRequest do
    def read_headers(req) do
      HTTP1Request.read_headers(req, :http, [])
    end

    def read_req_body(%HTTP1Request{state: :headers_read} = req, _opts) do
      # TODO 
      {:ok, <<>>, %{req | state: :body_read}}
    end

    def read_req_body(%HTTP1Request{state: :new}, _opts), do: raise(UnreadHeadersError)
    def read_req_body(%HTTP1Request{}, _opts), do: raise(AlreadyReadError)

    def send_resp(%HTTP1Request{state: state}, _, _, _) when state in [:sent, :chunking_out],
      do: raise(AlreadySentError)

    def send_resp(%HTTP1Request{socket: socket, version: version} = req, status, headers, response) do
      # TODO refactor and add error handling
      resp = [version, " ", to_string(status), "\r\n", HTTP1Request.format_headers(headers, response), "\r\n", response]
      Socket.send(socket, resp)

      {:ok, nil, %{req | state: :sent}}
    end

    def send_file(%HTTP1Request{} = req, _status, _headers, _path, _offset, _length) do
      # TODO
      {:ok, nil, %{req | state: :sent}}
    end

    def send_chunked(%HTTP1Request{} = req, _status, _headers) do
      # TODO
      {:ok, nil, %{req | state: :chunking_out}}
    end

    def chunk(%HTTP1Request{} = req, _chunk) do
      # TODO
      {:ok, nil, req}
    end

    def inform(_req, _status, _headers) do
      {:error, :not_supported}
    end

    def push(_req, _path, _headers) do
      {:error, :not_supported}
    end

    def get_local_data(%HTTP1Request{socket: socket}) do
      {{ip, port}, _} = Socket.endpoints(socket)
      %{address: ip, port: port, ssl_cert: nil}
    end

    def get_peer_data(%HTTP1Request{socket: socket}) do
      {_, {ip, port}} = Socket.endpoints(socket)
      %{address: ip, port: port, ssl_cert: nil}
    end

    def get_http_protocol(%HTTP1Request{version: version}), do: version

    def keepalive?(%HTTP1Request{version: version}), do: version == "HTTP/1.1"
  end

  def request(%Socket{} = socket), do: {:ok, %__MODULE__{socket: socket}}

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

  def format_headers(headers, body) do
    [{"content-length", body |> byte_size() |> to_string()} | headers]
    |> Enum.flat_map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
  end

  defp version({1, 1}), do: "HTTP/1.1"
  defp version({1, 0}), do: "HTTP/1.0"
end
