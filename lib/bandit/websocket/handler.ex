defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455. As a Handler, this works with raw
  # ThousandIsland Sockets and supports HTTP/1.1-sourced WebSocket connections

  use ThousandIsland.Handler

  alias Bandit.WebSocket.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    connection = Connection.init(state.sock)

    Connection.handle_connection(state.conn, socket, connection)
    |> case do
      {:continue, connection} ->
        state =
          state
          |> Map.drop([:conn, :plug])
          |> Map.put(:connection, connection)
          |> Map.put(:buffer, <<>>)

        {:continue, state}

      {:close, _} ->
        {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(&Frame.deserialize(&1))
    |> Enum.reduce_while({:continue, state}, fn
      {:ok, frame}, {:continue, state} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:continue, connection} ->
            {:cont, {:continue, %{state | connection: connection, buffer: <<>>}}}

          {:close, connection} ->
            {:halt, {:close, %{state | connection: connection, buffer: <<>>}}}

          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection, buffer: <<>>}}}
        end

      {:more, rest}, {:continue, state} ->
        {:halt, {:continue, %{state | buffer: rest}}}

      {:error, message}, {:continue, state} ->
        {:halt, {:error, message, state}}
    end)
  end

  @impl ThousandIsland.Handler
  def handle_close(socket, %{connection: connection}),
    do: Connection.handle_close(socket, connection)

  def handle_close(_socket, _state), do: :ok

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state), do: Connection.handle_shutdown(socket, state.connection)

  @impl ThousandIsland.Handler
  def handle_error(reason, socket, state),
    do: Connection.handle_error(reason, socket, state.connection)

  @impl ThousandIsland.Handler
  def handle_timeout(socket, state), do: Connection.handle_timeout(socket, state.connection)

  def handle_info({:plug_conn, :sent}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
end
