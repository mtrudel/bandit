defmodule Bandit.HTTP2.Handler do
  @moduledoc false
  # An HTTP/2 handler, this module comprises the primary interface between Thousand Island and an
  # HTTP connection. It is responsible for:
  #
  # * All socket-level sending and receiving from the client
  # * Coordinating the parsing of frames & attendant error handling
  # * Tracking connection state as represented by a `Bandit.HTTP2.Connection` struct

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    connection = Bandit.HTTP2.Connection.init(socket, state.plug, state.opts)
    {:continue, Map.merge(state, %{buffer: <<>>, connection: connection})}
  rescue
    error -> rescue_error(error, __STACKTRACE__, socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(
      &Bandit.HTTP2.Frame.deserialize(&1, state.connection.local_settings.max_frame_size)
    )
    |> Enum.reduce_while(state, fn
      {:ok, frame}, state ->
        connection = Bandit.HTTP2.Connection.handle_frame(frame, socket, state.connection)
        {:cont, %{state | connection: connection, buffer: <<>>}}

      {:more, rest}, state ->
        {:halt, %{state | buffer: rest}}

      {:error, error_code, message}, _state ->
        # We encountered an error while deserializing the frame. Let the connection figure out
        # how to respond to it
        raise Bandit.HTTP2.Errors.ConnectionError, message: message, error_code: error_code
    end)
    |> then(&{:continue, &1})
  rescue
    error -> rescue_error(error, __STACKTRACE__, socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state) do
    Bandit.HTTP2.Connection.close_connection(
      Bandit.HTTP2.Errors.no_error(),
      "Server shutdown",
      socket,
      state.connection
    )
  end

  @impl ThousandIsland.Handler
  def handle_timeout(socket, state) do
    Bandit.HTTP2.Connection.close_connection(
      Bandit.HTTP2.Errors.no_error(),
      "Client timeout",
      socket,
      state.connection
    )
  end

  def handle_call({:peer_data, _stream_id}, _from, {socket, state}) do
    {:reply, Bandit.SocketHelpers.peer_data(socket), {socket, state}, socket.read_timeout}
  end

  def handle_call({:sock_data, _stream_id}, _from, {socket, state}) do
    {:reply, Bandit.SocketHelpers.sock_data(socket), {socket, state}, socket.read_timeout}
  end

  def handle_call({:ssl_data, _stream_id}, _from, {socket, state}) do
    {:reply, Bandit.SocketHelpers.ssl_data(socket), {socket, state}, socket.read_timeout}
  end

  def handle_call({{:send_data, data, end_stream}, stream_id}, from, {socket, state}) do
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

    connection =
      Bandit.HTTP2.Connection.send_data(
        stream_id,
        data,
        end_stream,
        unblock,
        socket,
        state.connection
      )

    {:noreply, {socket, %{state | connection: connection}}, socket.read_timeout}
  rescue
    error -> rescue_error_handle_info(error, __STACKTRACE__, socket, state)
  end

  def handle_info({{:send_headers, headers, end_stream}, stream_id}, {socket, state}) do
    connection =
      Bandit.HTTP2.Connection.send_headers(
        stream_id,
        headers,
        end_stream,
        socket,
        state.connection
      )

    {:noreply, {socket, %{state | connection: connection}}, socket.read_timeout}
  rescue
    error -> rescue_error_handle_info(error, __STACKTRACE__, socket, state)
  end

  def handle_info({{:send_recv_window_update, size_increment}, stream_id}, {socket, state}) do
    Bandit.HTTP2.Connection.send_recv_window_update(
      stream_id,
      size_increment,
      socket,
      state.connection
    )

    {:noreply, {socket, state}, socket.read_timeout}
  rescue
    error -> rescue_error_handle_info(error, __STACKTRACE__, socket, state)
  end

  def handle_info({{:send_rst_stream, error_code}, stream_id}, {socket, state}) do
    Bandit.HTTP2.Connection.send_rst_stream(stream_id, error_code, socket, state.connection)
    {:noreply, {socket, state}, socket.read_timeout}
  rescue
    error -> rescue_error_handle_info(error, __STACKTRACE__, socket, state)
  end

  def handle_info({{:close_connection, error_code, msg}, _stream_id}, {socket, state}) do
    _ = Bandit.HTTP2.Connection.close_connection(error_code, msg, socket, state.connection)
    {:stop, :normal, {socket, state}}
  end

  def handle_info({:EXIT, pid, _reason}, {socket, state}) do
    connection = Bandit.HTTP2.Connection.stream_terminated(pid, state.connection)
    {:noreply, {socket, %{state | connection: connection}}, socket.read_timeout}
  end

  defp rescue_error(error, stacktrace, socket, state) do
    do_rescue_error(error, stacktrace, socket, state)
    {:close, state}
  end

  defp rescue_error_handle_info(error, stacktrace, socket, state) do
    do_rescue_error(error, stacktrace, socket, state)
    {:stop, :normal}
  end

  defp do_rescue_error(error, stacktrace, socket, state) do
    _ =
      if state[:connection] do
        Bandit.HTTP2.Connection.close_connection(
          error.error_code,
          error.message,
          socket,
          state[:connection]
        )
      end

    Bandit.Logger.maybe_log_protocol_error(error, stacktrace, state.opts, plug: state.plug)
  end
end
