defmodule Bandit.HTTPRequest do
  @moduledoc """
  Defines behaviour to be implemented by HTTP Request handlers in addition 
  to those defined by `Plug.Conn.Adapter`. 
  """

  @type payload :: term

  @callback request(ThousandIsland.Socket.t()) :: {:ok, module(), payload}

  @callback read_headers(payload) :: {:ok, keyword(), String.t(), String.t(), payload} | {:error, String.t()}

  @callback get_local_data(payload) :: Plug.Conn.Adapter.peer_data()

  @callback keepalive?(payload) :: bool()

  defmodule UnreadHeadersError, do: defexception(message: "Headers have not been read yet")
  defmodule UnsupportedTransferEncodingError, do: defexception(message: "Unsupported Transfer-Encoding")
  defmodule AlreadyReadError, do: defexception(message: "Body has already been read")
  defmodule AlreadySentError, do: defexception(message: "Response has already been written (or is being chunked out)")
end
