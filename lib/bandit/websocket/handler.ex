defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455

  use ThousandIsland.Handler

  alias Bandit.WebSocket.{Frame, HTTP1Handshake}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    HTTP1Handshake.send_http1_handshake(socket, state.conn)
    {:continue, Map.drop(state, [:conn, :plug])}
  end

  @impl ThousandIsland.Handler
  def handle_data(_data, _socket, state) do
    {:continue, state}
  end
end
