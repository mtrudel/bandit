defmodule Bandit.Adapter do
  @moduledoc """
  Defines behaviour to be implemented by HTTP Adapters in addition 
  to those defined by `Plug.Conn.Adapter`. 
  """

  @typedoc """
  The requested URI exactly as it appears in the request line at the beginning 
  of an HTTP request, NOT broken up into path & query components.
  """
  @type request_uri :: String.t()

  @doc """
  Returns the initial connection data (method, request URI and headers) for a
  client connection.
  """
  @callback read_headers(Plug.Conn.Adapter.payload()) ::
              {:ok, Plug.Conn.headers(), Plug.Conn.method(), request_uri(),
               Plug.Conn.Adapter.payload()}
              | {:error, String.t()}

  @doc """
  Returns the local connection info (port, IP and SSL certificate) for a connection.
  """
  @callback get_local_data(Plug.Conn.Adapter.payload()) :: Plug.Conn.Adapter.peer_data()

  defmodule UnreadHeadersError do
    defexception(message: "Headers have not been read yet")

    @moduledoc """
    Raised by bandit adapters if they are commanded to send a request before request headers
    have been read.
    """
  end

  defmodule AlreadyReadError do
    defexception(message: "Body has already been read")

    @moduledoc """
    Raised by bandit adapters if they are commanded to read a body which already been read.
    """
  end

  defmodule AlreadySentError do
    defexception(message: "Response has already been written (or is being chunked out)")

    @moduledoc """
    Raised by bandit adapters if they are commanded to send a response when one has already 
    been sent.
    """
  end
end
