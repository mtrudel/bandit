defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{plug: plug} = state) do
    # TODO - implement HTTP/2
    {:ok, :close, state}
  end
end
