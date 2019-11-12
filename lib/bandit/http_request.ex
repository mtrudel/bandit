defmodule Bandit.HTTPRequest do
  @type state :: :new | :headers_read | :body_read | :sent | :chunking_out

  defstruct state: :new,
            socket: nil,
            version: nil,
            method: nil,
            path: nil,
            read_buffer: nil

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

  def request(%Socket{} = socket), do: {:ok, %__MODULE__{socket: socket}}

  def read_headers(%__MODULE__{state: :new, socket: socket} = req) do
    case Bandit.HTTPParser.parse_headers(socket) do
      {:ok, version, method, path, headers, rest} ->
        {:ok, headers, %{req | version: version, method: method, path: path, read_buffer: rest, state: :headers_read}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_headers(%__MODULE__{}), do: raise(AlreadyReadError)

  def read_body(%__MODULE__{state: :headers_read} = req, _opts) do
    # TODO 
    {:ok, <<>>, %{req | state: :body_read}}
  end

  def read_body(%__MODULE__{state: :new}, _opts), do: raise(UnreadHeadersError)
  def read_body(%__MODULE__{}, _opts), do: raise(AlreadyReadError)

  def send_resp(%__MODULE__{state: state}, _, _, _) when state in [:sent, :chunking_out], do: raise(AlreadySentError)

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    # TODO refactor and add error handling
    resp = [version, " ", to_string(status), "\r\n", format_headers(headers, response), "\r\n", response]
    Socket.send(socket, resp)

    {:ok, %{req | state: :sent}}
  end

  def send_file(%__MODULE__{}, _status, _headers, _path, _offset, _length) do
    # TODO
  end

  def send_chunked(%__MODULE__{}, _status, _headers) do
    # TODO
  end

  def send_chunk(%__MODULE__{}, _chunk) do
    # TODO
  end

  def endpoints(%__MODULE__{socket: socket}), do: Socket.endpoints(socket)

  def version(%__MODULE__{version: :new}), do: raise(UnreadHeadersError)
  def version(%__MODULE__{version: version}), do: version

  defp format_headers(headers, body) do
    [{"content-length", body |> byte_size() |> to_string()} | headers]
    |> Enum.flat_map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
  end
end
