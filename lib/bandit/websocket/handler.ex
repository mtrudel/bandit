defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455

  use ThousandIsland.Handler

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    Bandit.WebSocket.HTTP1Handshake.send_http1_handshake(socket, state.conn)
    {:continue, Map.delete(state, :conn)}
  end

  @impl ThousandIsland.Handler
  def handle_data(_data, _socket, state) do
    {:continue, state}
  end
end
