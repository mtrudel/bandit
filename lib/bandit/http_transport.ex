defmodule Bandit.HTTPTransport do
  @moduledoc false
  # A behaviour implemented by the lower level transports (HTTP/1 and HTTP/2) to encapsulate the
  # low-level mechanics needed to complete an HTTP request/response cycle. Implementations of this
  # behaviour should be broadly concerned with the protocol-specific aspects of a connection, and
  # can rely on higher-level code taking care of shared HTTP semantics

  @type transport :: Bandit.HTTP2.Stream.t()

  @typedoc "How the response body is to be delivered"
  @type body_disposition :: :raw | :chunk_encoded | :no_body | :inform

  @callback version(transport()) :: Plug.Conn.Adapter.http_protocol()

  @callback read_headers(transport()) ::
              {:ok, Plug.Conn.method(), Bandit.Pipeline.request_target(), Plug.Conn.headers(),
               transport()}

  @callback read_data(transport(), opts :: keyword()) ::
              {:ok, iodata(), transport()} | {:more, iodata(), transport()}

  @callback send_headers(transport(), Plug.Conn.status(), Plug.Conn.headers(), body_disposition()) ::
              transport()

  @callback send_data(transport(), data :: iodata(), end_request :: boolean()) :: transport()

  @callback sendfile(transport(), Path.t(), offset :: integer(), length :: integer() | :all) ::
              transport()

  @callback ensure_completed(transport()) :: transport()
end
