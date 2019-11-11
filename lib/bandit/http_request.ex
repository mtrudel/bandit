defmodule Bandit.HTTPRequest do
  @type state :: :new | :headers_read | :body_read | :sent | :chunking_out

  defstruct state: :new,
            socket: nil,
            version: nil,
            verb: nil,
            path: nil,
            headers: nil,
            read_buffer: []

  defmodule AlreadyReadError do
    defexception message: "Body has already been read"
  end

  defmodule AlreadySentError do
    defexception message: "Response has already been written (or is being chunked out)"
  end

  alias Bandit.HTTPRequest.{AlreadyReadError, AlreadySentError}
  alias ThousandIsland.Socket

  def request(%Socket{} = socket), do: %__MODULE__{socket: socket}

  def endpoints(%__MODULE__{socket: socket}), do: Socket.endpoints(socket)

  def version(%__MODULE__{version: version}), do: version

  def read_headers(%__MODULE__{state: :new, socket: socket, read_buffer: read_buffer}) do
    # TODO
  end

  def read_headers(%__MODULE__{} = req), do: req

  def read_body(%__MODULE__{state: :new} = req, opts) do
    req |> read_headers() |> read_body(opts)
  end

  def read_body(%__MODULE__{state: :headers_read, socket: socket, read_buffer: read_buffer}, opts) do
    # TODO 
  end

  def read_body(%__MODULE__{}, _opts), do: raise(AlreadyReadError)

  def send_resp(%__MODULE__{state: state}, _, _, _) when state in [:sent, :chunking_out] do
    raise(AlreadySentError)
  end

  def send_resp(%__MODULE__{socket: socket, version: version} = req, status, headers, response) do
    resp = [version, " ", status, "\r\n", format_headers(headers, response), "\r\n", response]
    Socket.send(socket, resp)

    %{req | state: :sent}
  end

  def send_file(%__MODULE__{}, status, headers, path, offset, length) do
  end

  def send_chunked(%__MODULE__{} = req, status, headers) do
    # TODO
  end

  def send_chunk(%__MODULE__{} = req, chunk) do
    # TODO
  end

  defp format_headers(headers, body) do
    headers
    |> Keyword.put("content-length", byte_size(body))
    |> Enum.flat_map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
  end
end
