defmodule Bandit.HTTP2.Handler do
  @moduledoc false
  # An HTTP/2 handler, this module comprises the primary interface between Thousand Island and an
  # HTTP connection. It is responsible for:
  #
  # * All socket-level sending and receiving from the client
  # * Coordinating the parsing of frames & attendant error handling
  # * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs

  use ThousandIsland.Handler

  alias Bandit.HTTP2.{Connection, Errors, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    with {:ok, connection} <-
           Connection.init(
             socket,
             state.plug,
             state.opts.http_2,
             Map.get(state, :initial_request),
             Map.get(state, :remote_settings)
           ) do
      {:continue, state |> Map.merge(%{buffer: <<>>, connection: connection})}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(&Frame.deserialize(&1, state.connection.local_settings.max_frame_size))
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

      {:error, {:connection, code, reason}}, {:continue, state} ->
        # We encountered an error while deserializing the frame. Let the connection figure out
        # how to respond to it
        case Connection.shutdown_connection(code, reason, socket, state.connection) do
          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection, buffer: <<>>}}}
        end
    end)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state) do
    Connection.shutdown_connection(Errors.no_error(), "Server shutdown", socket, state.connection)
  end

  @impl ThousandIsland.Handler
  def handle_timeout(socket, state) do
    Connection.shutdown_connection(Errors.no_error(), "Client timeout", socket, state.connection)
  end

  def handle_call({:send_headers, stream_id, headers, end_stream}, _from, {socket, state}) do
    case Connection.send_headers(stream_id, headers, end_stream, socket, state.connection) do
      {:ok, connection} ->
        {:reply, :ok, {socket, %{state | connection: connection}}, socket.read_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}, socket.read_timeout}
    end
  end

  def handle_call({:send_data, stream_id, data, end_stream}, from, {socket, state}) do
    # In 'normal' cases where there is sufficient space in the send windows for this message to be
    # sent, Connection will call `unblock` synchronously in the `Connection.send_data` call below.
    # In cases where there is not enough space in the connection window, Connection will call
    # `unblock` at some point in the future once space opens up in the window. This
    # keeps this code simple in that we can blindly send noreply here and let Connection handle
    # the separate cases. This ensures that we have backpressure all the way back to the
    # stream's handler process in the event of window overruns.
    #
    # Note that the above only applies to the connection-level send window; stream-level windows
    # are managed internally by the stream and are not considered here at all. If the stream has
    # managed to send this message, it is because there was enough room in the stream's send
    # window to do so.
    unblock = fn -> GenServer.reply(from, :ok) end

    case Connection.send_data(stream_id, data, end_stream, unblock, socket, state.connection) do
      {:ok, connection} ->
        {:noreply, {socket, %{state | connection: connection}}, socket.read_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}, socket.read_timeout}
    end
  end

  def handle_call({:send_recv_window_update, stream_id, size_increment}, _from, {socket, state}) do
    Connection.send_recv_window_update(stream_id, size_increment, socket, state.connection)
    {:reply, :ok, {socket, state}, socket.read_timeout}
  end

  def handle_call({:send_rst_stream, stream_id, error_code}, _from, {socket, state}) do
    Connection.send_rst_stream(stream_id, error_code, socket, state.connection)
    {:reply, :ok, {socket, state}, socket.read_timeout}
  end

  def handle_call({:shutdown_connection, error_code, msg}, _from, {socket, state}) do
    case Connection.shutdown_connection(error_code, msg, socket, state.connection) do
      {:close, _connection} -> {:stop, :normal, {socket, state}}
      {:error, reason, _connection} -> {:stop, reason, {socket, state}}
    end
  end

  def handle_info({:EXIT, pid, reason}, {socket, state}) do
    {:ok, connection} = Connection.stream_terminated(pid, reason, state.connection)
    {:noreply, {socket, %{state | connection: connection}}, socket.read_timeout}
  end
end
