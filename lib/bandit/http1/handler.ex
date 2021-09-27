defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  alias Bandit.HTTP1.ConnPipeline

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{plug: plug} = state) do
    case ConnPipeline.run(data, socket, plug) do
      {:ok, true} -> {:ok, :continue, state}
      {:ok, false} -> {:ok, :close, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end
