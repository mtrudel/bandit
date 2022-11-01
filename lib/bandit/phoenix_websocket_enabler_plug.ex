defmodule Bandit.PhoenixWebSocketEnablerPlug do
  @moduledoc false
  # This module is temporary, and should be removed once Phoenix lands Sock support
  # See https://github.com/phoenixframework/phoenix/pull/5030#issuecomment-1298291845

  @behaviour Plug

  def init({endpoint, opts}), do: {endpoint, endpoint.init(opts)}

  def call(conn, {endpoint, opts}) do
    conn
    |> Plug.Conn.put_private(:phoenix_websocket_upgrade, &websocket_upgrade/4)
    |> endpoint.call(opts)
  end

  def websocket_upgrade(conn, handler, state, connection_opts) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {handler, state, connection_opts})
  end
end
