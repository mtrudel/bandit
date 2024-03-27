defprotocol Bandit.HTTPTransport do
  @moduledoc false
  # A protocol implemented by the lower level transports (HTTP/1 and HTTP/2) to encapsulate the
  # low-level mechanics needed to complete an HTTP request/response cycle. Implementations of this
  # protocol should be broadly concerned with the protocol-specific aspects of a connection, and
  # can rely on higher-level code taking care of shared HTTP semantics

  @typedoc "How the response body is to be delivered"
  @type body_disposition :: :raw | :chunk_encoded | :no_body | :inform

  @spec transport_info(t()) :: Bandit.TransportInfo.t()
  def transport_info(transport)

  @spec version(t()) :: Plug.Conn.Adapter.http_protocol()
  def version(transport)

  @spec read_headers(t()) ::
          {:ok, Plug.Conn.method(), Bandit.Pipeline.request_target(), Plug.Conn.headers(), t()}
  def read_headers(transport)

  @spec read_data(t(), opts :: keyword()) :: {:ok, iodata(), t()} | {:more, iodata(), t()}
  def read_data(transport, opts)

  @spec send_headers(t(), Plug.Conn.status(), Plug.Conn.headers(), body_disposition()) :: t()
  def send_headers(transport, status, heeaders, disposition)

  @spec send_data(t(), data :: iodata(), end_request :: boolean()) :: t()
  def send_data(transport, data, end_request)

  @spec sendfile(t(), Path.t(), offset :: integer(), length :: integer() | :all) :: t()
  def sendfile(transport, path, offset, length)

  @spec ensure_completed(t()) :: t()
  def ensure_completed(transport)

  @spec supported_upgrade?(t(), atom()) :: boolean()
  def supported_upgrade?(transport, protocol)

  @spec send_on_error(t(), struct()) :: t()
  def send_on_error(transport, error)
end
