defmodule Bandit.HTTPRequest do
  @moduledoc """
  Defines behaviour to be implemented by HTTP Request handlers in addition 
  to those defined by `Plug.Conn.Adapter`. 
  """

  @type payload :: term

  @callback request(ThousandIsland.Socket.t(), binary() | list()) :: {:ok, module(), payload}

  @callback read_headers(payload) :: {:ok, keyword(), String.t(), String.t(), payload} | {:error, String.t()}

  @callback get_local_data(payload) :: Plug.Conn.Adapter.peer_data()

  @callback keepalive?(payload) :: boolean()

  @callback close(payload) :: :ok

  @callback send_fallback_resp(payload, code :: pos_integer()) :: :ok

  defmodule UnreadHeadersError, do: defexception(message: "Headers have not been read yet")
  defmodule AlreadyReadError, do: defexception(message: "Body has already been read")
  defmodule AlreadySentError, do: defexception(message: "Response has already been written (or is being chunked out)")
end
