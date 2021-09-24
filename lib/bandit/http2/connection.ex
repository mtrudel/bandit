defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  require Logger

  alias ThousandIsland.{Handler, Socket, Transport}

  alias Bandit.HTTP2.{
    Connection,
    Errors,
    FlowControl,
    Frame,
    Settings,
    Stream,
    StreamCollection
  }

  defstruct local_settings: %Settings{},
            remote_settings: %Settings{},
            fragment_frame: nil,
            send_hpack_state: HPAX.new(4096),
            recv_hpack_state: HPAX.new(4096),
            send_window_size: 65_535,
            recv_window_size: 65_535,
            streams: %StreamCollection{},
            pending_sends: [],
            peer: nil,
            plug: nil

  @typedoc "A description of a connection error"
  @type error :: {:connection, Errors.error_code(), String.t()}

  @typedoc "Encapsulates the state of an HTTP/2 connection"
  @type t :: %__MODULE__{
          local_settings: Settings.t(),
          remote_settings: Settings.t(),
          fragment_frame: Frame.Headers.t() | nil,
          send_hpack_state: HPAX.Table.t(),
          recv_hpack_state: HPAX.Table.t(),
          send_window_size: non_neg_integer(),
          recv_window_size: non_neg_integer(),
          streams: StreamCollection.t(),
          pending_sends: [{Stream.stream_id(), iodata(), boolean(), fun()}],
          peer: Transport.socket_info(),
          plug: Bandit.plug()
        }

  @spec init(Socket.t(), Bandit.plug()) :: {:ok, t()}
  def init(socket, plug) do
    peer = Socket.peer_info(socket)
    connection = %__MODULE__{plug: plug, peer: peer}
    # Send SETTINGS frame per RFC7540§3.5
    %Frame.Settings{ack: false, settings: connection.local_settings}
    |> send_frame(socket, connection)

    {:ok, connection}
  end

  #
  # Receiving while expecting CONTINUATION frames is a special case (RFC7540§6.10); handle it first
  #

  @spec handle_frame(Frame.frame(), Socket.t(), t()) :: Handler.handler_result()
  def handle_frame(
        %Frame.Continuation{end_headers: true, stream_id: stream_id} = frame,
        socket,
        %Connection{fragment_frame: %Frame.Headers{stream_id: stream_id}} = connection
      ) do
    header_block = connection.fragment_frame.fragment <> frame.fragment
    header_frame = %{connection.fragment_frame | end_headers: true, fragment: header_block}
    handle_frame(header_frame, socket, %{connection | fragment_frame: nil})
  end

  def handle_frame(
        %Frame.Continuation{end_headers: false, stream_id: stream_id} = frame,
        _socket,
        %Connection{fragment_frame: %Frame.Headers{stream_id: stream_id}} = connection
      ) do
    header_block = connection.fragment_frame.fragment <> frame.fragment
    header_frame = %{connection.fragment_frame | fragment: header_block}
    {:ok, :continue, %{connection | fragment_frame: header_frame}}
  end

  def handle_frame(_frame, socket, %Connection{fragment_frame: %Frame.Headers{}} = connection) do
    shutdown_connection(
      Errors.protocol_error(),
      "Expected CONTINUATION frame (RFC7540§6.10)",
      socket,
      connection
    )
  end

  #
  # Connection-level receiving
  #

  def handle_frame(%Frame.Settings{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Settings{ack: false} = frame, socket, connection) do
    %Frame.Settings{ack: true} |> send_frame(socket, connection)

    streams =
      connection.streams
      |> StreamCollection.update_initial_send_window_size(frame.settings.initial_window_size)
      |> StreamCollection.update_max_concurrent_streams(frame.settings.max_concurrent_streams)

    send_hpack_state = HPAX.resize(connection.send_hpack_state, frame.settings.header_table_size)

    do_pending_sends(socket, %{
      connection
      | remote_settings: frame.settings,
        streams: streams,
        send_hpack_state: send_hpack_state
    })
  end

  def handle_frame(%Frame.Ping{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Ping{ack: false} = frame, socket, connection) do
    %Frame.Ping{ack: true, payload: frame.payload} |> send_frame(socket, connection)
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Goaway{}, socket, connection) do
    shutdown_connection(Errors.no_error(), "Received GOAWAY", socket, connection)
  end

  def handle_frame(%Frame.WindowUpdate{stream_id: 0} = frame, socket, connection) do
    case FlowControl.update_send_window(connection.send_window_size, frame.size_increment) do
      {:ok, new_window} ->
        do_pending_sends(socket, %{connection | send_window_size: new_window})

      {:error, error} ->
        shutdown_connection(Errors.flow_control_error(), error, socket, connection)
    end
  end

  #
  # Stream-level receiving
  #

  def handle_frame(%Frame.WindowUpdate{} = frame, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <- Stream.recv_window_update(stream, frame.size_increment),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      do_pending_sends(socket, %{connection | streams: streams})
    else
      {:error, {:connection, error_code, error_message}} ->
        shutdown_connection(error_code, error_message, socket, connection)

      {:error, {:stream, stream_id, error_code, error_message}} ->
        handle_stream_error(stream_id, error_code, error_message, socket, connection)

      {:error, error} ->
        shutdown_connection(Errors.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(
        %Frame.Headers{stream_id: stream_id, stream_dependency: stream_id},
        socket,
        connection
      ) do
    handle_stream_error(
      stream_id,
      Errors.protocol_error(),
      "Stream cannot list itself as a dependency (RFC7540§5.3.1)",
      socket,
      connection
    )
  end

  def handle_frame(%Frame.Headers{end_headers: true} = frame, socket, connection) do
    with block <- frame.fragment,
         end_stream <- frame.end_stream,
         {:hpack, {:ok, headers, recv_hpack_state}} <-
           {:hpack, HPAX.decode(block, connection.recv_hpack_state)},
         {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <-
           Stream.recv_headers(stream, headers, end_stream, connection.peer, connection.plug),
         {:ok, stream} <- Stream.recv_end_of_stream(stream, end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, :continue, %{connection | recv_hpack_state: recv_hpack_state, streams: streams}}
    else
      {:hpack, _} ->
        shutdown_connection(Errors.compression_error(), "Header decode error", socket, connection)

      {:error, {:connection, error_code, error_message}} ->
        shutdown_connection(error_code, error_message, socket, connection)

      {:error, {:stream, stream_id, error_code, error_message}} ->
        handle_stream_error(stream_id, error_code, error_message, socket, connection)

      {:error, error} ->
        shutdown_connection(Errors.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(%Frame.Headers{end_headers: false} = frame, _socket, connection) do
    {:ok, :continue, %{connection | fragment_frame: frame}}
  end

  def handle_frame(%Frame.Continuation{}, socket, connection) do
    shutdown_connection(
      Errors.protocol_error(),
      "Received unexpected CONTINUATION frame (RFC7540§6.10)",
      socket,
      connection
    )
  end

  def handle_frame(%Frame.Data{} = frame, socket, connection) do
    {connection_recv_window_size, connection_window_increment} =
      FlowControl.compute_recv_window(connection.recv_window_size, byte_size(frame.data))

    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream, stream_window_increment} <- Stream.recv_data(stream, frame.data),
         {:ok, stream} <- Stream.recv_end_of_stream(stream, frame.end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      if connection_window_increment > 0 do
        %Frame.WindowUpdate{stream_id: 0, size_increment: connection_window_increment}
        |> send_frame(socket, connection)
      end

      if stream_window_increment > 0 do
        %Frame.WindowUpdate{stream_id: frame.stream_id, size_increment: stream_window_increment}
        |> send_frame(socket, connection)
      end

      {:ok, :continue,
       %{connection | recv_window_size: connection_recv_window_size, streams: streams}}
    else
      {:error, {:connection, error_code, error_message}} ->
        shutdown_connection(error_code, error_message, socket, connection)

      {:error, {:stream, stream_id, error_code, error_message}} ->
        # If we're erroring out on a stream error, RFC7540§6.9 stipulates that we MUST take into
        # account the sizes of errored frames. As such, ensure that we update our connection
        # window to reflect that space taken up by this frame. We needn't worry about the stream's
        # window since we're shutting it down anyway

        connection = %{connection | recv_window_size: connection_recv_window_size}
        handle_stream_error(stream_id, error_code, error_message, socket, connection)

      {:error, error} ->
        shutdown_connection(Errors.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(
        %Frame.Priority{stream_id: stream_id, dependent_stream_id: stream_id},
        socket,
        connection
      ) do
    handle_stream_error(
      stream_id,
      Errors.protocol_error(),
      "Stream cannot list itself as a dependency (RFC7540§5.3.1)",
      socket,
      connection
    )
  end

  def handle_frame(%Frame.Priority{}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.RstStream{} = frame, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <- Stream.recv_rst_stream(stream, frame.error_code),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, :continue, %{connection | streams: streams}}
    else
      {:error, {:connection, error_code, error_message}} ->
        shutdown_connection(error_code, error_message, socket, connection)

      {:error, error} ->
        shutdown_connection(Errors.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(%Frame.PushPromise{}, socket, connection) do
    shutdown_connection(
      Errors.protocol_error(),
      "Received PUSH_PROMISE (RFC7540§8.2)",
      socket,
      connection
    )
  end

  # Catch-all handler for unknown frame types

  def handle_frame(%Frame.Unknown{} = frame, _socket, connection) do
    Logger.warn("Unknown frame (#{inspect(Map.from_struct(frame))})")

    {:ok, :continue, connection}
  end

  # Shared logic to send any pending frames upon adjustment of our send window
  defp do_pending_sends(socket, connection) do
    connection.pending_sends
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, :continue, connection}, fn pending_send,
                                                          {:ok, :continue, connection} ->
      connection = connection |> Map.update!(:pending_sends, &List.delete(&1, pending_send))

      {stream_id, rest, end_stream, on_unblock} = pending_send

      case do_send_data(stream_id, rest, end_stream, on_unblock, socket, connection) do
        {:ok, true, connection} ->
          on_unblock.()
          {:cont, {:ok, :continue, connection}}

        {:ok, false, connection} ->
          {:cont, {:ok, :continue, connection}}

        {:error, error} ->
          {:halt, {:error, error, connection}}
      end
    end)
  end

  #
  # Error handling on receipt of frames
  #

  @spec shutdown_connection(Errors.error_code(), term(), Socket.t(), t()) ::
          {:ok, :close, t()} | {:error, term(), t()}
  def shutdown_connection(error_code, reason, socket, connection) do
    last_remote_stream_id = StreamCollection.last_remote_stream_id(connection.streams)

    %Frame.Goaway{last_stream_id: last_remote_stream_id, error_code: error_code}
    |> send_frame(socket, connection)

    if error_code == Errors.no_error() do
      {:ok, :close, connection}
    else
      {:error, reason, connection}
    end
  end

  defp handle_stream_error(stream_id, error_code, reason, socket, connection) do
    {:ok, stream} = StreamCollection.get_stream(connection.streams, stream_id)
    Stream.terminate_stream(stream, {:bandit, reason})

    %Frame.RstStream{stream_id: stream_id, error_code: error_code}
    |> send_frame(socket, connection)

    {:ok, :continue, connection}
  end

  #
  # Sending logic
  #
  # All callers of functions below will be from stream tasks, looked up via pid
  #

  #
  # Stream-level sending
  #

  @spec send_headers(Stream.stream_id(), pid(), Plug.Conn.headers(), boolean(), Socket.t(), t()) ::
          {:ok, t()} | {:error, term()}
  def send_headers(stream_id, pid, headers, end_stream, socket, connection) do
    with enc_headers <- Enum.map(headers, fn {key, value} -> {:store, key, value} end),
         {block, send_hpack_state} <- HPAX.encode(enc_headers, connection.send_hpack_state),
         {:ok, stream} <- StreamCollection.get_stream(connection.streams, stream_id),
         :ok <- Stream.owner?(stream, pid),
         {:ok, stream} <- Stream.send_headers(stream),
         {:ok, stream} <- Stream.send_end_of_stream(stream, end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      %Frame.Headers{
        stream_id: stream_id,
        end_stream: end_stream,
        fragment: block
      }
      |> send_frame(socket, connection)

      {:ok, %{connection | send_hpack_state: send_hpack_state, streams: streams}}
    end
  end

  @spec send_data(Stream.stream_id(), pid(), iodata(), boolean(), fun(), Socket.t(), t()) ::
          {:ok, boolean(), t()} | {:error, term()}
  def send_data(stream_id, pid, data, end_stream, on_unblock, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, stream_id),
         :ok <- Stream.owner?(stream, pid) do
      do_send_data(stream_id, data, end_stream, on_unblock, socket, connection)
    end
  end

  defp do_send_data(stream_id, data, end_stream, on_unblock, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, stream_id),
         stream_window_size <- Stream.get_send_window_size(stream),
         connection_window_size <- connection.send_window_size,
         max_bytes_to_send <- max(min(stream_window_size, connection_window_size), 0),
         {data_to_send, bytes_to_send, rest} <- split_data(data, max_bytes_to_send),
         {:ok, stream} <- Stream.send_data(stream, bytes_to_send),
         connection <- %{connection | send_window_size: connection_window_size - bytes_to_send},
         end_stream_to_send <- end_stream && rest == <<>>,
         {:ok, stream} <- Stream.send_end_of_stream(stream, end_stream_to_send),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      if end_stream_to_send || IO.iodata_length(data_to_send) > 0 do
        %Frame.Data{stream_id: stream_id, end_stream: end_stream_to_send, data: data_to_send}
        |> send_frame(socket, connection)
      end

      if byte_size(rest) == 0 do
        {:ok, true, %{connection | streams: streams}}
      else
        pending_sends = [{stream_id, rest, end_stream, on_unblock} | connection.pending_sends]
        {:ok, false, %{connection | streams: streams, pending_sends: pending_sends}}
      end
    end
  end

  defp split_data(data, desired_length) do
    data_length = IO.iodata_length(data)

    if data_length <= desired_length do
      {data, data_length, <<>>}
    else
      <<to_send::binary-size(desired_length), rest::binary>> = IO.iodata_to_binary(data)
      {to_send, desired_length, rest}
    end
  end

  @spec send_push(Stream.stream_id(), Plug.Conn.headers(), Socket.t(), t()) ::
          {:ok, t()} | {:error, term()}
  def send_push(stream_id, headers, socket, connection) do
    with :ok <- can_send_push_promises(connection),
         :ok <- StreamCollection.can_send_new_push_promise(connection.streams),
         promised_stream_id <- StreamCollection.next_local_stream_id(connection.streams),
         {:ok, stream} <- StreamCollection.get_stream(connection.streams, promised_stream_id),
         {:ok, stream} <- Stream.send_push_headers(stream, headers),
         enc_headers <- Enum.map(headers, fn {key, value} -> {:store, key, value} end),
         {block, send_hpack_state} <- HPAX.encode(enc_headers, connection.send_hpack_state),
         :ok <- send_push_promise_frame(stream_id, promised_stream_id, block, socket, connection),
         {:ok, stream} <- Stream.start_push(stream, headers, connection.peer, connection.plug),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, %{connection | send_hpack_state: send_hpack_state, streams: streams}}
    end
  end

  defp can_send_push_promises(%__MODULE__{remote_settings: %Settings{enable_push: true}}), do: :ok
  defp can_send_push_promises(_), do: {:error, :client_disabled_push}

  defp send_push_promise_frame(stream_id, promised_stream_id, block, socket, connection) do
    %Frame.PushPromise{
      stream_id: stream_id,
      promised_stream_id: promised_stream_id,
      fragment: block
    }
    |> send_frame(socket, connection)

    :ok
  end

  @spec stream_terminated(pid(), term(), Socket.t(), t()) :: {:ok, t()} | {:error, term()}
  def stream_terminated(pid, reason, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_active_stream_by_pid(connection.streams, pid),
         {:ok, stream, error_code} <- Stream.stream_terminated(stream, reason),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      if !is_nil(error_code) do
        %Frame.RstStream{stream_id: stream.stream_id, error_code: error_code}
        |> send_frame(socket, connection)
      end

      {:ok, %{connection | streams: streams}}
    end
  end

  #
  # Utility functions
  #

  defp send_frame(frame, socket, connection) do
    Socket.send(socket, Frame.serialize(frame, connection.remote_settings.max_frame_size))
  end
end
