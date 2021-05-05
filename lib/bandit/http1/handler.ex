defmodule Bandit.HTTP1.Handler do
  @moduledoc """
  An HTTP 1.0 & 1.1 Thousand Island Handler
  """

  use ThousandIsland.Handler

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{plug: plug} = state) do
    req = %Bandit.HTTP1.Adapter{socket: socket, buffer: data}

    case Bandit.ConnPipeline.run(Bandit.HTTP1.Adapter, req, plug) do
      {:ok, req} ->
        if Bandit.HTTP1.Adapter.keepalive?(req) do
          {:ok, :continue, state}
        else
          {:ok, :close, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end
