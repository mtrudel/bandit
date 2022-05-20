defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455. As a Handler, this works with raw
  # ThousandIsland Sockets and supports HTTP/1.1-sourced WebSocket connections

  use ThousandIsland.Handler

  alias Bandit.WebSocket.Connection

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    Connection.handle_connection(socket, state.conn)
    |> case do
      {:continue, connection} ->
        state =
          state
          |> Map.drop([:conn, :plug])
          |> Map.put(:connection, connection)

        {:continue, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    Connection.handle_data(data, socket, state.connection)
    |> case do
      {:continue, connection} ->
        {:continue, %{state | connection: connection}}
    end
  end

  # TODO - handle close & error callbacks

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
end
