defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  defstruct local_settings: %{},
            remote_settings: %{},
            fragment_frame: nil,
            send_hpack_state: HPack.Table.new(4096),
            recv_hpack_state: HPack.Table.new(4096),
            streams: %Bandit.HTTP2.StreamCollection{},
            peer: nil,
            plug: nil

  alias Bandit.HTTP2.{Connection, Constants, Frame, Stream, StreamCollection}

  def init(socket, plug) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} ->
        peer = ThousandIsland.Socket.peer_info(socket)
        connection = %__MODULE__{plug: plug, peer: peer}
        # Send SETTINGS frame per RFC7540§3.5
        %Frame.Settings{ack: false, settings: connection.local_settings}
        |> send_frame(socket)

        {:ok, connection}

      _ ->
        {:error, "Did not receive expected HTTP/2 connection preface (RFC7540§3.5)"}
    end
  end

  #
  # Receiving while expecting CONTINUATION frames is a special case (RFC7540§6.10); handle it first
  #

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
    handle_error(
      Constants.protocol_error(),
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
    %Frame.Settings{ack: true} |> send_frame(socket)
    {:ok, :continue, %{connection | remote_settings: frame.settings}}
  end

  def handle_frame(%Frame.Ping{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Ping{ack: false} = frame, socket, connection) do
    %Frame.Ping{ack: true, payload: frame.payload} |> send_frame(socket)
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Goaway{}, socket, connection) do
    handle_error(Constants.no_error(), "Received GOAWAY", socket, connection)
  end

  #
  # Stream-level receiving
  #

  def handle_frame(%Frame.Headers{end_headers: true} = frame, socket, connection) do
    with block <- frame.fragment,
         {:ok, recv_hpack_state, headers} <- HPack.decode(block, connection.recv_hpack_state),
         {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <- Stream.recv_headers(stream, headers, connection.peer, connection.plug),
         {:ok, stream} <- Stream.recv_end_of_stream(stream, frame.end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, :continue, %{connection | recv_hpack_state: recv_hpack_state, streams: streams}}
    else
      {:error, :decode_error} ->
        handle_error(Constants.compression_error(), "Header decode error", socket, connection)

      # https://github.com/OleMchls/elixir-hpack/issues/16
      other when is_binary(other) ->
        handle_error(Constants.compression_error(), "Header decode error", socket, connection)

      {:error, {:connection, error_code, error_message}} ->
        handle_error(error_code, error_message, socket, connection)

      {:error, {:stream, error_code, error_message}} ->
        handle_stream_error(frame.stream_id, error_code, error_message, socket, connection)

      {:error, error} ->
        handle_error(Constants.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(%Frame.Headers{end_headers: false} = frame, _socket, connection) do
    {:ok, :continue, %{connection | fragment_frame: frame}}
  end

  def handle_frame(%Frame.Continuation{}, socket, connection) do
    handle_error(
      Constants.protocol_error(),
      "Received unexpected CONTINUATION frame (RFC7540§6.10)",
      socket,
      connection
    )
  end

  def handle_frame(%Frame.Data{} = frame, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <- Stream.recv_data(stream, frame.data),
         {:ok, stream} <- Stream.recv_end_of_stream(stream, frame.end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, :continue, %{connection | streams: streams}}
    else
      {:error, {:connection, error_code, error_message}} ->
        handle_error(error_code, error_message, socket, connection)

      {:error, error} ->
        handle_error(Constants.internal_error(), error, socket, connection)
    end
  end

  def handle_frame(%Frame.RstStream{} = frame, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, frame.stream_id),
         {:ok, stream} <- Stream.recv_rst_stream(stream, frame.error_code),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      {:ok, :continue, %{connection | streams: streams}}
    else
      {:error, {:connection, error_code, error_message}} ->
        handle_error(error_code, error_message, socket, connection)

      {:error, error} ->
        handle_error(Constants.internal_error(), error, socket, connection)
    end
  end

  #
  # Stream-level sending
  #

  def send_headers(stream_id, pid, headers, end_stream, socket, connection) do
    with {:ok, send_hpack_state, block} <- HPack.encode(headers, connection.send_hpack_state),
         {:ok, stream} <- StreamCollection.get_stream(connection.streams, stream_id),
         :ok <- Stream.owner?(stream, pid),
         {:ok, stream} <- Stream.send_headers(stream),
         {:ok, stream} <- Stream.send_end_of_stream(stream, end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      %Frame.Headers{
        stream_id: stream_id,
        end_headers: true,
        end_stream: end_stream,
        fragment: block
      }
      |> send_frame(socket)

      {:ok, %{connection | send_hpack_state: send_hpack_state, streams: streams}}
    else
      {:error, :encode_error} ->
        # Not explcitily documented in RFC7540
        handle_error(Constants.compression_error(), "Header encode error", socket, connection)

      {:error, {:connection, error_code, error_message}} ->
        handle_error(error_code, error_message, socket, connection)

      {:error, error} ->
        {:error, error}
    end
  end

  def send_data(stream_id, pid, data, end_stream, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_stream(connection.streams, stream_id),
         :ok <- Stream.owner?(stream, pid),
         {:ok, stream} <- Stream.send_data(stream),
         {:ok, stream} <- Stream.send_end_of_stream(stream, end_stream),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      %Frame.Data{stream_id: stream_id, end_stream: end_stream, data: data}
      |> send_frame(socket)

      {:ok, %{connection | streams: streams}}
    else
      {:error, {:connection, error_code, error_message}} ->
        handle_error(error_code, error_message, socket, connection)

      {:error, error} ->
        {:error, error}
    end
  end

  #
  # Connection-level error handling
  #

  def handle_error(error_code, reason, socket, connection) do
    last_remote_stream_id = StreamCollection.last_remote_stream_id(connection.streams)

    %Frame.Goaway{last_stream_id: last_remote_stream_id, error_code: error_code}
    |> send_frame(socket)

    if error_code == Constants.no_error() do
      {:ok, :close, connection}
    else
      {:error, reason, connection}
    end
  end

  def connection_terminated(socket, connection) do
    last_remote_stream_id = StreamCollection.last_remote_stream_id(connection.streams)

    %Frame.Goaway{last_stream_id: last_remote_stream_id, error_code: Constants.no_error()}
    |> send_frame(socket)

    :ok
  end

  #
  # Stream-level error handling
  #

  def handle_stream_error(stream_id, error_code, _reason, socket, connection) do
    %Frame.RstStream{stream_id: stream_id, error_code: error_code}
    |> send_frame(socket)

    {:ok, :continue, connection}
  end

  def stream_terminated(pid, reason, socket, connection) do
    with {:ok, stream} <- StreamCollection.get_active_stream_by_pid(connection.streams, pid),
         {:ok, stream, error_code} <- Stream.stream_terminated(stream, reason),
         {:ok, streams} <- StreamCollection.put_stream(connection.streams, stream) do
      if !is_nil(error_code) do
        %Frame.RstStream{stream_id: stream.stream_id, error_code: error_code}
        |> send_frame(socket)
      end

      {:ok, %{connection | streams: streams}}
    end
  end

  #
  # Utility functions
  #

  defp send_frame(frame, socket) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
