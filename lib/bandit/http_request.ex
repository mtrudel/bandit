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
end
