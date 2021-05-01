defmodule Bandit.InitialHandler do
  @moduledoc """
  The initial protocol implementation used for all connections. Switches to a 
  specific protocol implementation based on configuration, ALPN negotiation, and
  line heuristics.
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # TODO For now just go straight to HTTP 1{.1} handler
    {:ok, :continue, state |> Map.put(:handler_module, Bandit.HTTP1Handler)}
  end
end
