defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455, structured as a ThousandIsland.Handler

  use ThousandIsland.Handler

  alias Bandit.WebSocket.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {websock, websock_opts, connection_opts} = state.upgrade_opts

    connection_opts
    |> Keyword.take([:fullsweep_after, :max_heap_size])
    |> Enum.each(fn {key, value} -> :erlang.process_flag(key, value) end)

    connection_opts = Keyword.merge(state.opts.websocket, connection_opts)

    state =
      state
      |> Map.take([:handler_module])
      |> Map.put(:buffer, <<>>)

    case Connection.init(websock, websock_opts, connection_opts, socket) do
      {:continue, connection} ->
        case Keyword.get(connection_opts, :timeout) do
          nil -> {:continue, Map.put(state, :connection, connection)}
          timeout -> {:continue, Map.put(state, :connection, connection), {:persistent, timeout}}
        end

      {:error, reason, connection} ->
        {:error, reason, Map.put(state, :connection, connection)}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(
      &Frame.deserialize(&1, Keyword.get(state.connection.opts, :max_frame_size, 0))
    )
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
        {:halt, {:error, {:deserializing, message}, state}}
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

  def handle_info(msg, {socket, state}) do
    case Connection.handle_info(msg, socket, state.connection) do
      {:continue, connection_state} ->
        {:noreply, {socket, %{state | connection: connection_state}}, socket.read_timeout}

      {:error, reason, connection_state} ->
        {:stop, reason, {socket, %{state | connection: connection_state}}}
    end
  end
end
