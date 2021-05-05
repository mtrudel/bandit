defmodule Bandit.InitialHandler do
  @moduledoc """
  The initial protocol implementation used for all connections. Switches to a 
  specific protocol implementation based on configuration, ALPN negotiation, and
  line heuristics.
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # 1. If we have a protocol from TLS, set up a protocol for it.
    # 2. Else, Consume enough to ensure that we can validate the protocol in use. Limits here for safety.
    # 3. Ensure that this is a protocol we are configured to run.
    # 4. Set up state as if this was an initial call on a dedicated handler_module
    # 4. Write handler_module into state (include data in buffer)

    {:ok, :continue, state |> Map.put(:handler_module, Bandit.HTTP1.Handler)}
  end
end
