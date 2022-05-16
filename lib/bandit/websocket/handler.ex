defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    {:continue, state}
  end

  def http1_handshake?(%Plug.Conn{} = conn) do
    false
  end
end
