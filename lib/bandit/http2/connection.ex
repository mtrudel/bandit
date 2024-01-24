defmodule Bandit.HTTP2.Connection do
  @moduledoc false
  # Represents the state of an HTTP/2 connection

  require Logger

  alias ThousandIsland.{Handler, Socket}

  alias Bandit.HTTP2.{
    Connection,
    Errors,
    FlowControl,
    Frame,
    Settings,
    Stream,
    StreamCollection,
    StreamProcess
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
            transport_info: nil,
            telemetry_span: nil,
            plug: nil,
            opts: []

  @typedoc "A description of a connection error"
  @type error :: {:connection, Errors.error_code(), String.t()}

  @type initial_request ::
          {Plug.Conn.method(), Bandit.Pipeline.request_target(), Plug.Conn.headers(), binary()}

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
          pending_sends: [{StreamCollection.stream_id(), iodata(), boolean(), fun()}],
          transport_info: Bandit.TransportInfo.t(),
          telemetry_span: ThousandIsland.Telemetry.t(),
          plug: Bandit.Pipeline.plug_def(),
          opts: keyword()
        }

  @spec init(
          Socket.t(),
          Bandit.Pipeline.plug_def(),
          keyword(),
          initial_request() | nil,
          Settings.t() | nil
        ) ::
          {:ok, t()}
  def init(socket, plug, opts, initial_request \\ nil, remote_settings \\ nil) do
    transport_info =
      case Bandit.TransportInfo.init(socket) do
        {:ok, transport_info} -> transport_info
        {:error, reason} -> raise "Unable to obtain transport_info: #{inspect(reason)}"
      end

    connection = %__MODULE__{
      local_settings: struct!(Settings, Keyword.get(opts, :default_local_settings, [])),
      remote_settings: remote_settings || %Settings{},
      transport_info: transport_info,
      telemetry_span: ThousandIsland.Socket.telemetry_span(socket),
      plug: plug,
      opts: opts
    }

    # Send SETTINGS frame per RFC9113§3.4
    _ =
      %Frame.Settings{ack: false, settings: connection.local_settings}
      |> send_frame(socket, connection)

    if is_nil(initial_request) do
      {:ok, connection}
    else
      handle_initial_request(initial_request, socket, connection)
    end
  end

  defp handle_initial_request({method, request_target, headers, data}, _socket, connection) do
    {_, _, _, path} = request_target
    headers = [{":scheme", "http"}, {":method", method}, {":path", path} | headers]

    streams =
      with_stream(connection, 1, fn stream ->
        Stream.deliver_headers(stream, headers)
        Stream.deliver_data(stream, data)
        Stream.deliver_end_of_stream(stream)
      end)

    {:ok, %{connection | streams: streams}}
  end

  #
  # Receiving while expecting CONTINUATION frames is a special case (RFC9113§6.10); handle it first
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
    {:continue, %{connection | fragment_frame: header_frame}}
  end

  def handle_frame(_frame, _socket, %Connection{fragment_frame: %Frame.Headers{}}) do
    connection_error!("Expected CONTINUATION frame (RFC9113§6.10)")
  end

  #
  # Connection-level receiving
  #

  def handle_frame(%Frame.Settings{ack: true}, _socket, connection) do
    {:continue, connection}
  end

  def handle_frame(%Frame.Settings{ack: false} = frame, socket, connection) do
    _ = %Frame.Settings{ack: true} |> send_frame(socket, connection)

    send_hpack_state = HPAX.resize(connection.send_hpack_state, frame.settings.header_table_size)

    delta = frame.settings.initial_window_size - connection.remote_settings.initial_window_size

    StreamCollection.get_pids(connection.streams)
    |> Enum.each(&Stream.deliver_send_window_update(&1, delta))

    do_pending_sends(socket, %{
      connection
      | remote_settings: frame.settings,
        send_hpack_state: send_hpack_state
    })
  end

  def handle_frame(%Frame.Ping{ack: true}, _socket, connection) do
    {:continue, connection}
  end

  def handle_frame(%Frame.Ping{ack: false} = frame, socket, connection) do
    _ = %Frame.Ping{ack: true, payload: frame.payload} |> send_frame(socket, connection)
    {:continue, connection}
  end

  def handle_frame(%Frame.Goaway{}, socket, connection) do
    shutdown_connection(Errors.no_error(), "Received GOAWAY", socket, connection)
  end

  def handle_frame(%Frame.WindowUpdate{stream_id: 0} = frame, socket, connection) do
    case FlowControl.update_send_window(connection.send_window_size, frame.size_increment) do
      {:ok, new_window} -> do_pending_sends(socket, %{connection | send_window_size: new_window})
      {:error, error} -> connection_error!(error, Errors.flow_control_error())
    end
  end

  #
  # Stream-level receiving
  #

  def handle_frame(%Frame.WindowUpdate{} = frame, _socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Stream.deliver_send_window_update(stream, frame.size_increment)
      end)

    {:continue, %{connection | streams: streams}}
  end

  def handle_frame(%Frame.Headers{end_headers: true} = frame, _socket, connection) do
    case HPAX.decode(frame.fragment, connection.recv_hpack_state) do
      {:ok, headers, recv_hpack_state} ->
        streams =
          with_stream(connection, frame.stream_id, fn stream ->
            Stream.deliver_headers(stream, headers)
            if frame.end_stream, do: Stream.deliver_end_of_stream(stream)
          end)

        {:continue, %{connection | recv_hpack_state: recv_hpack_state, streams: streams}}

      _ ->
        connection_error!("Header decode error", Errors.compression_error())
    end
  end

  def handle_frame(%Frame.Headers{end_headers: false} = frame, _socket, connection) do
    {:continue, %{connection | fragment_frame: frame}}
  end

  def handle_frame(%Frame.Continuation{}, _socket, _connection) do
    connection_error!("Received unexpected CONTINUATION frame (RFC9113§6.10)")
  end

  def handle_frame(%Frame.Data{} = frame, socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Stream.deliver_data(stream, frame.data)
        if frame.end_stream, do: Stream.deliver_end_of_stream(stream)
      end)

    {recv_window_size, window_increment} =
      FlowControl.compute_recv_window(connection.recv_window_size, byte_size(frame.data))

    _ =
      if window_increment > 0 do
        %Frame.WindowUpdate{stream_id: 0, size_increment: window_increment}
        |> send_frame(socket, connection)
      end

    {:continue, %{connection | recv_window_size: recv_window_size, streams: streams}}
  end

  def handle_frame(%Frame.Priority{}, _socket, connection) do
    {:continue, connection}
  end

  def handle_frame(%Frame.RstStream{} = frame, _socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Stream.deliver_rst_stream(stream, frame.error_code)
      end)

    {:continue, %{connection | streams: streams}}
  end

  # Catch-all handler for unknown frame types

  def handle_frame(%Frame.Unknown{} = frame, _socket, connection) do
    Logger.warning("Unknown frame (#{inspect(Map.from_struct(frame))})")
    {:continue, connection}
  end

  defp with_stream(connection, stream_id, fun) do
    case StreamCollection.get_pid(connection.streams, stream_id) do
      pid when is_pid(pid) ->
        fun.(pid)
        connection.streams

      :new ->
        if accept_stream?(connection) do
          stream =
            Stream.init(
              self(),
              stream_id,
              connection.remote_settings.initial_window_size,
              connection.transport_info
            )

          case StreamProcess.start_link(
                 stream,
                 connection.plug,
                 connection.opts,
                 connection.telemetry_span
               ) do
            {:ok, pid} ->
              streams = StreamCollection.insert(connection.streams, stream_id, pid)
              with_stream(%{connection | streams: streams}, stream_id, fun)

            _ ->
              raise "Unable to start stream process"
          end
        else
          connection_error!("Connection count exceeded", Errors.refused_stream())
        end

      :closed ->
        connection.streams

      :invalid ->
        connection_error!("Received invalid stream identifier")
    end
  end

  defp accept_stream?(connection) do
    max_requests = Keyword.get(connection.opts, :max_requests, 0)
    max_requests == 0 || StreamCollection.stream_count(connection.streams) < max_requests
  end

  # Shared logic to send any pending frames upon adjustment of our send window
  defp do_pending_sends(socket, connection) do
    connection.pending_sends
    |> Enum.reverse()
    |> Enum.reduce({:continue, connection}, fn pending_send, {:continue, connection} ->
      connection = connection |> Map.update!(:pending_sends, &List.delete(&1, pending_send))

      {stream_id, rest, end_stream, on_unblock} = pending_send

      {:ok, connection} = send_data(stream_id, rest, end_stream, on_unblock, socket, connection)
      {:continue, connection}
    end)
  end

  #
  # Sending logic
  #
  # All callers of functions below will be from stream processes
  #

  #
  # Stream-level sending
  #

  @spec send_headers(
          StreamCollection.stream_id(),
          Plug.Conn.headers(),
          boolean(),
          Socket.t(),
          t()
        ) ::
          {:ok, t()}
  def send_headers(stream_id, headers, end_stream, socket, connection) do
    with enc_headers <- Enum.map(headers, fn {key, value} -> {:store, key, value} end),
         {block, send_hpack_state} <- HPAX.encode(enc_headers, connection.send_hpack_state) do
      _ =
        %Frame.Headers{
          stream_id: stream_id,
          end_stream: end_stream,
          fragment: block
        }
        |> send_frame(socket, connection)

      {:ok, %{connection | send_hpack_state: send_hpack_state}}
    end
  end

  @spec send_data(StreamCollection.stream_id(), iodata(), boolean(), fun(), Socket.t(), t()) ::
          {:ok, t()}
  def send_data(stream_id, data, end_stream, on_unblock, socket, connection) do
    with connection_window_size <- connection.send_window_size,
         max_bytes_to_send <- max(connection_window_size, 0),
         {data_to_send, bytes_to_send, rest} <- split_data(data, max_bytes_to_send),
         connection <- %{connection | send_window_size: connection_window_size - bytes_to_send},
         end_stream_to_send <- end_stream && byte_size(rest) == 0 do
      _ =
        if end_stream_to_send || bytes_to_send > 0 do
          %Frame.Data{stream_id: stream_id, end_stream: end_stream_to_send, data: data_to_send}
          |> send_frame(socket, connection)
        end

      if byte_size(rest) == 0 do
        on_unblock.()
        {:ok, connection}
      else
        pending_sends = [{stream_id, rest, end_stream, on_unblock} | connection.pending_sends]
        {:ok, %{connection | pending_sends: pending_sends}}
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

  @spec send_recv_window_update(StreamCollection.stream_id(), non_neg_integer(), Socket.t(), t()) ::
          :ok
  def send_recv_window_update(stream_id, size_increment, socket, connection) do
    _ =
      %Frame.WindowUpdate{stream_id: stream_id, size_increment: size_increment}
      |> send_frame(socket, connection)

    :ok
  end

  @spec send_rst_stream(StreamCollection.stream_id(), Errors.error_code(), Socket.t(), t()) :: :ok
  def send_rst_stream(stream_id, error_code, socket, connection) do
    _ =
      %Frame.RstStream{stream_id: stream_id, error_code: error_code}
      |> send_frame(socket, connection)

    :ok
  end

  @spec stream_terminated(pid(), t()) :: {:ok, t()}
  def stream_terminated(pid, connection) do
    {:ok, %{connection | streams: StreamCollection.delete(connection.streams, pid)}}
  end

  #
  # Helper functions
  #

  @spec shutdown_connection(Errors.error_code(), term(), Socket.t(), t()) ::
          {:close, t()} | {:error, term(), t()}
  def shutdown_connection(error_code, reason, socket, connection) do
    last_stream_id = StreamCollection.last_stream_id(connection.streams)

    _ =
      %Frame.Goaway{last_stream_id: last_stream_id, error_code: error_code}
      |> send_frame(socket, connection)

    if error_code == Errors.no_error() do
      {:close, connection}
    else
      {:error, reason, connection}
    end
  end

  @spec connection_error!(term()) :: no_return()
  @spec connection_error!(term(), Errors.error_code()) :: no_return()
  defp connection_error!(message, error_code \\ Errors.protocol_error()) do
    raise Errors.ConnectionError, message: message, error_code: error_code
  end

  defp send_frame(frame, socket, connection) do
    Socket.send(socket, Frame.serialize(frame, connection.remote_settings.max_frame_size))
  end
end
