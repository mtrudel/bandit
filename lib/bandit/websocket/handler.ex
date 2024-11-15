defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455, structured as a ThousandIsland.Handler

  use ThousandIsland.Handler

  alias Bandit.Extractor
  alias Bandit.WebSocket.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {websock, websock_opts, connection_opts} = state.upgrade_opts

    connection_opts
    |> Keyword.take([:fullsweep_after, :max_heap_size])
    |> Enum.each(fn {key, value} -> :erlang.process_flag(key, value) end)

    connection_opts = Keyword.merge(state.opts.websocket, connection_opts)

    primitive_ops_module =
      Keyword.get(state.opts.websocket, :primitive_ops_module, Bandit.PrimitiveOps.WebSocket)

    state =
      state
      |> Map.take([:handler_module])
      |> Map.put(:extractor, Extractor.new(Frame, primitive_ops_module, connection_opts))

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
    state.extractor
    |> Extractor.push_data(data)
    |> pop_frame(socket, state)
  end

  defp pop_frame(extractor, socket, state) do
    case Extractor.pop_frame(extractor) do
      {extractor, {:ok, frame}} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:continue, connection} ->
            pop_frame(extractor, socket, %{state | extractor: extractor, connection: connection})

          {:close, connection} ->
            {:close, %{state | extractor: extractor, connection: connection}}

          {:error, reason, connection} ->
            {:error, reason, %{state | extractor: extractor, connection: connection}}
        end

      {extractor, {:error, reason}} ->
        {:error, {:deserializing, reason}, %{state | extractor: extractor}}

      {extractor, :more} ->
        {:continue, %{state | extractor: extractor}}
    end
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
