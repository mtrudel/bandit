defmodule Bandit.InitialHandler do
  @moduledoc """
  The initial protocol implementation used for all connections. Switches to a 
  specific protocol implementation based on configuration, ALPN negotiation, and
  line heuristics.
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    # TODO: If we don't have a negotiated protocol, try consuming enough to see if we can 
    # figure out what protocol is in use

    next_module =
      case ThousandIsland.Socket.negotiated_protocol(socket) do
        {:ok, "h2"} -> Bandit.HTTP2.Handler
        _ -> Bandit.HTTP1.Handler
      end

    Bandit.DelegatingHandler.handle_connection(socket, %{state | handler_module: next_module})
  end
end
