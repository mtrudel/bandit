defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  defstruct local_settings: %{},
            remote_settings: %{},
            send_header_state: HPack.Table.new(4096),
            recv_header_state: HPack.Table.new(4096),
            last_local_stream_id: 0,
            last_remote_stream_id: 0,
            streams: %{},
            plug: nil

  require Integer
  require Logger

  alias Bandit.HTTP2.{Constants, Frame, Stream}

  def init(socket, plug) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} ->
        connection = %__MODULE__{plug: plug}
        # Send SETTINGS frame per RFC7540§3.5
        %Frame.Settings{ack: false, settings: connection.local_settings}
        |> send_frame(socket)

        {:ok, connection}

      _ ->
        {:error, "Did not receive expected HTTP/2 connection preface (RFC7540§3.5)"}
    end
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
    close(Constants.no_error(), socket, connection)
  end

  #
  # Stream-level receiving
  #

  def handle_frame(%Frame.Headers{end_headers: true} = frame, socket, connection) do
    with {:ok, recv_header_state, headers} <-
           HPack.decode(frame.header_block_fragment, connection.recv_header_state),
         :ok <- ok_to_init_stream?(frame.stream_id, connection.last_remote_stream_id),
         %{address: peer} <- ThousandIsland.Socket.peer_info(socket),
         {:ok, pid} <- Stream.start_link(self(), frame.stream_id, peer, headers, connection.plug) do
      if frame.end_stream, do: Process.send(pid, :end_stream, [])

      connection =
        connection
        |> Map.put(:recv_header_state, recv_header_state)
        |> Map.put(:last_remote_stream_id, frame.stream_id)
        |> Map.update!(:streams, &Map.put(&1, frame.stream_id, {:open, pid}))
        |> Map.update!(:streams, &update_stream_on_recv(&1, frame.stream_id, frame.end_stream))

      {:ok, :continue, connection}
    else
      {:error, :decode_error} -> close(Constants.compression_error(), socket, connection)
      # https://github.com/OleMchls/elixir-hpack/issues/16
      other when is_binary(other) -> close(Constants.compression_error(), socket, connection)
      {:error, :even_stream_id} -> close(Constants.protocol_error(), socket, connection)
      {:error, :old_stream_id} -> close(Constants.protocol_error(), socket, connection)
    end
  end

  def handle_frame(%Frame.Data{} = frame, _socket, connection) do
    case pid_for_recv(connection.streams, frame.stream_id) do
      {:ok, pid} ->
        connection =
          connection
          |> Map.update!(:streams, &update_stream_on_recv(&1, frame.stream_id, frame.end_stream))

        Process.send(pid, {:data, frame.data}, [])
        if frame.end_stream, do: Process.send(pid, :end_stream, [])

        {:ok, :continue, connection}

      {:error, reason} ->
        Logger.warn("Encountered error while receiving DATA frame: #{reason}. Ignoring")
        {:ok, :continue, connection}
    end
  end

  defp ok_to_init_stream?(stream_id, last_stream_id) do
    cond do
      Integer.is_even(stream_id) -> {:error, :even_stream_id}
      stream_id <= last_stream_id -> {:error, :old_stream_id}
      true -> :ok
    end
  end

  defp pid_for_recv(streams, stream_id) do
    case Map.get(streams, stream_id) do
      {stream_state, pid} when stream_state not in [:remote_closed, :closed] -> {:ok, pid}
      {_stream_state, _pid} -> {:error, :remote_end_closed}
      nil -> {:error, :invalid_stream}
    end
  end

  defp update_stream_on_recv(streams, stream_id, end_stream) do
    case {Map.get(streams, stream_id), end_stream} do
      {{:local_closed, _pid}, true} -> Map.delete(streams, stream_id)
      {{:open, pid}, true} -> Map.put(streams, stream_id, {:remote_closed, pid})
      _ -> streams
    end
  end

  #
  # Stream-level sending
  #

  def send_headers(stream_id, pid, headers, end_stream, socket, connection) do
    with :ok <- ok_to_send?(connection.streams, stream_id, pid),
         {:ok, send_header_state, header_block} <-
           HPack.encode(headers, connection.send_header_state) do
      %Frame.Headers{
        stream_id: stream_id,
        end_headers: true,
        end_stream: end_stream,
        header_block_fragment: header_block
      }
      |> send_frame(socket)

      connection =
        connection
        |> Map.put(:send_header_state, send_header_state)
        |> Map.update!(:streams, &update_stream_on_send(&1, stream_id, end_stream))

      {:ok, connection}
    else
      {:error, :encode_error} ->
        # Not explcitily documented in RFC7540
        close(Constants.compression_error(), socket, connection)
        {:close, :encode_error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_data(stream_id, pid, data, end_stream, socket, connection) do
    case ok_to_send?(connection.streams, stream_id, pid) do
      :ok ->
        %Frame.Data{stream_id: stream_id, end_stream: end_stream, data: data}
        |> send_frame(socket)

        connection =
          connection
          |> Map.update!(:streams, &update_stream_on_send(&1, stream_id, end_stream))

        {:ok, connection}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # State management per RFC7540§5.1
  defp ok_to_send?(streams, stream_id, pid) do
    case Map.get(streams, stream_id) do
      {stream_state, ^pid} when stream_state not in [:local_closed, :closed] -> :ok
      {_stream_state, ^pid} -> {:error, :local_end_closed}
      {_stream_state, _pid} -> {:error, :not_owner}
      nil -> {:error, :invalid_stream}
    end
  end

  defp update_stream_on_send(streams, stream_id, end_stream) do
    case {Map.get(streams, stream_id), end_stream} do
      {{:remote_closed, _pid}, true} -> Map.delete(streams, stream_id)
      {{:open, pid}, true} -> Map.put(streams, stream_id, {:local_closed, pid})
      _ -> streams
    end
  end

  #
  # Connection-level error handling
  #

  def handle_error(0, error_code, _reason, socket, connection) do
    close(error_code, socket, connection)
  end

  defp close(error_code, socket, connection) do
    %Frame.Goaway{last_stream_id: connection.last_remote_stream_id, error_code: error_code}
    |> send_frame(socket)

    {:ok, :close, connection}
  end

  #
  # Stream-level error handling
  #

  def stream_terminated(pid, _reason, _socket, connection) do
    connection.streams
    |> Enum.find(fn {_stream_id, {_stream_state, stream_pid}} -> stream_pid == pid end)
    |> case do
      {stream_id, _} ->
        {:ok, connection |> Map.update!(:streams, &Map.delete(&1, stream_id))}

      nil ->
        {:ok, connection}
    end
  end

  #
  # Utility functions
  #

  defp send_frame(frame, socket) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
