defmodule Bandit.HTTP2.Connection do
  @moduledoc false
  # Represents the state of an HTTP/2 connection, in a process-free manner. An instance of this
  # struct is maintained as the state of a `Bandit.HTTP2.Handler` process, and it moves an HTTP/2
  # connection through its lifecycle by calling functions defined on this module

  require Logger

  defstruct local_settings: %Bandit.HTTP2.Settings{},
            remote_settings: %Bandit.HTTP2.Settings{},
            fragment_frame: nil,
            send_hpack_state: HPAX.new(4096),
            recv_hpack_state: HPAX.new(4096),
            send_window_size: 65_535,
            recv_window_size: 65_535,
            streams: %Bandit.HTTP2.StreamCollection{},
            pending_sends: [],
            transport_info: nil,
            telemetry_span: nil,
            plug: nil,
            opts: %{}

  @typedoc "Encapsulates the state of an HTTP/2 connection"
  @type t :: %__MODULE__{
          local_settings: Bandit.HTTP2.Settings.t(),
          remote_settings: Bandit.HTTP2.Settings.t(),
          fragment_frame: Bandit.HTTP2.Frame.Headers.t() | nil,
          send_hpack_state: HPAX.Table.t(),
          recv_hpack_state: HPAX.Table.t(),
          send_window_size: non_neg_integer(),
          recv_window_size: non_neg_integer(),
          streams: Bandit.HTTP2.StreamCollection.t(),
          pending_sends: [{Bandit.HTTP2.Stream.stream_id(), iodata(), boolean(), fun()}],
          transport_info: Bandit.TransportInfo.t(),
          telemetry_span: ThousandIsland.Telemetry.t(),
          plug: Bandit.Pipeline.plug_def(),
          opts: %{
            required(:http) => Bandit.http_options(),
            required(:http_2) => Bandit.http_2_options()
          }
        }

  @spec init(ThousandIsland.Socket.t(), Bandit.Pipeline.plug_def(), map()) :: t()
  def init(socket, plug, opts) do
    connection = %__MODULE__{
      local_settings:
        struct!(Bandit.HTTP2.Settings, Keyword.get(opts.http_2, :default_local_settings, [])),
      transport_info: Bandit.TransportInfo.init(socket),
      telemetry_span: ThousandIsland.Socket.telemetry_span(socket),
      plug: plug,
      opts: opts
    }

    # Send SETTINGS frame per RFC9113§3.4
    %Bandit.HTTP2.Frame.Settings{ack: false, settings: connection.local_settings}
    |> send_frame(socket, connection)

    connection
  end

  #
  # Receiving while expecting CONTINUATION frames is a special case (RFC9113§6.10); handle it first
  #

  @spec handle_frame(Bandit.HTTP2.Frame.frame(), ThousandIsland.Socket.t(), t()) :: t()
  def handle_frame(
        %Bandit.HTTP2.Frame.Continuation{end_headers: true, stream_id: stream_id} = frame,
        socket,
        %__MODULE__{fragment_frame: %Bandit.HTTP2.Frame.Headers{stream_id: stream_id}} =
          connection
      ) do
    header_block = connection.fragment_frame.fragment <> frame.fragment
    header_frame = %{connection.fragment_frame | end_headers: true, fragment: header_block}
    handle_frame(header_frame, socket, %{connection | fragment_frame: nil})
  end

  def handle_frame(
        %Bandit.HTTP2.Frame.Continuation{end_headers: false, stream_id: stream_id} = frame,
        _socket,
        %__MODULE__{fragment_frame: %Bandit.HTTP2.Frame.Headers{stream_id: stream_id}} =
          connection
      ) do
    fragment = connection.fragment_frame.fragment <> frame.fragment
    check_oversize_fragment!(fragment, connection)
    fragment_frame = %{connection.fragment_frame | fragment: fragment}
    %{connection | fragment_frame: fragment_frame}
  end

  def handle_frame(_frame, _socket, %__MODULE__{fragment_frame: %Bandit.HTTP2.Frame.Headers{}}) do
    connection_error!("Expected CONTINUATION frame (RFC9113§6.10)")
  end

  #
  # Connection-level receiving
  #

  def handle_frame(%Bandit.HTTP2.Frame.Settings{ack: true}, _socket, connection), do: connection

  def handle_frame(%Bandit.HTTP2.Frame.Settings{ack: false} = frame, socket, connection) do
    %Bandit.HTTP2.Frame.Settings{ack: true} |> send_frame(socket, connection)
    send_hpack_state = HPAX.resize(connection.send_hpack_state, frame.settings.header_table_size)
    delta = frame.settings.initial_window_size - connection.remote_settings.initial_window_size

    Bandit.HTTP2.StreamCollection.get_pids(connection.streams)
    |> Enum.each(&Bandit.HTTP2.Stream.deliver_send_window_update(&1, delta))

    do_pending_sends(socket, %{
      connection
      | remote_settings: frame.settings,
        send_hpack_state: send_hpack_state
    })
  end

  def handle_frame(%Bandit.HTTP2.Frame.Ping{ack: true}, _socket, connection), do: connection

  def handle_frame(%Bandit.HTTP2.Frame.Ping{ack: false} = frame, socket, connection) do
    %Bandit.HTTP2.Frame.Ping{ack: true, payload: frame.payload} |> send_frame(socket, connection)
    connection
  end

  def handle_frame(%Bandit.HTTP2.Frame.Goaway{}, _socket, connection), do: connection

  def handle_frame(%Bandit.HTTP2.Frame.WindowUpdate{stream_id: 0} = frame, socket, connection) do
    case Bandit.HTTP2.FlowControl.update_send_window(
           connection.send_window_size,
           frame.size_increment
         ) do
      {:ok, new_window} -> do_pending_sends(socket, %{connection | send_window_size: new_window})
      {:error, error} -> connection_error!(error, Bandit.HTTP2.Errors.flow_control_error())
    end
  end

  #
  # Stream-level receiving
  #

  def handle_frame(%Bandit.HTTP2.Frame.WindowUpdate{} = frame, _socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Bandit.HTTP2.Stream.deliver_send_window_update(stream, frame.size_increment)
      end)

    %{connection | streams: streams}
  end

  def handle_frame(%Bandit.HTTP2.Frame.Headers{end_headers: true} = frame, _socket, connection) do
    check_oversize_fragment!(frame.fragment, connection)

    case HPAX.decode(frame.fragment, connection.recv_hpack_state) do
      {:ok, headers, recv_hpack_state} ->
        streams =
          with_stream(connection, frame.stream_id, fn stream ->
            Bandit.HTTP2.Stream.deliver_headers(stream, headers, frame.end_stream)
          end)

        %{connection | recv_hpack_state: recv_hpack_state, streams: streams}

      _ ->
        connection_error!("Header decode error", Bandit.HTTP2.Errors.compression_error())
    end
  end

  def handle_frame(%Bandit.HTTP2.Frame.Headers{end_headers: false} = frame, _socket, connection) do
    check_oversize_fragment!(frame.fragment, connection)
    %{connection | fragment_frame: frame}
  end

  def handle_frame(%Bandit.HTTP2.Frame.Continuation{}, _socket, _connection) do
    connection_error!("Received unexpected CONTINUATION frame (RFC9113§6.10)")
  end

  def handle_frame(%Bandit.HTTP2.Frame.Data{} = frame, socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Bandit.HTTP2.Stream.deliver_data(stream, frame.data, frame.end_stream)
      end)

    {recv_window_size, window_increment} =
      Bandit.HTTP2.FlowControl.compute_recv_window(
        connection.recv_window_size,
        byte_size(frame.data)
      )

    if window_increment > 0 do
      %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 0, size_increment: window_increment}
      |> send_frame(socket, connection)
    end

    %{connection | recv_window_size: recv_window_size, streams: streams}
  end

  def handle_frame(%Bandit.HTTP2.Frame.Priority{}, _socket, connection), do: connection

  def handle_frame(%Bandit.HTTP2.Frame.RstStream{} = frame, _socket, connection) do
    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Bandit.HTTP2.Stream.deliver_rst_stream(stream, frame.error_code)
      end)

    %{connection | streams: streams}
  end

  # Catch-all handler for unknown frame types

  def handle_frame(%Bandit.HTTP2.Frame.Unknown{} = frame, _socket, connection) do
    Logger.warning("Unknown frame (#{inspect(Map.from_struct(frame))})", domain: [:bandit])
    connection
  end

  defp with_stream(connection, stream_id, fun) do
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id) do
      pid when is_pid(pid) or pid == :closed ->
        fun.(pid)
        connection.streams

      :new ->
        if accept_stream?(connection) do
          stream =
            Bandit.HTTP2.Stream.init(
              self(),
              stream_id,
              connection.remote_settings.initial_window_size,
              connection.transport_info
            )

          case Bandit.HTTP2.StreamProcess.start_link(
                 stream,
                 connection.plug,
                 connection.telemetry_span,
                 connection.opts
               ) do
            {:ok, pid} ->
              streams = Bandit.HTTP2.StreamCollection.insert(connection.streams, stream_id, pid)
              with_stream(%{connection | streams: streams}, stream_id, fun)

            _ ->
              raise "Unable to start stream process"
          end
        else
          connection_error!("Connection count exceeded", Bandit.HTTP2.Errors.refused_stream())
        end

      :invalid ->
        connection_error!("Received invalid stream identifier")
    end
  end

  defp accept_stream?(connection) do
    max_requests = Keyword.get(connection.opts.http_2, :max_requests, 0)

    max_requests == 0 ||
      Bandit.HTTP2.StreamCollection.stream_count(connection.streams) < max_requests
  end

  defp check_oversize_fragment!(fragment, connection) do
    if byte_size(fragment) > Keyword.get(connection.opts.http_2, :max_header_block_size, 50_000),
      do: connection_error!("Received overlong headers")
  end

  # Shared logic to send any pending frames upon adjustment of our send window
  defp do_pending_sends(socket, connection) do
    connection.pending_sends
    |> Enum.reverse()
    |> Enum.reduce(connection, fn pending_send, connection ->
      connection = connection |> Map.update!(:pending_sends, &List.delete(&1, pending_send))
      {stream_id, rest, end_stream, on_unblock} = pending_send
      send_data(stream_id, rest, end_stream, on_unblock, socket, connection)
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
          Bandit.HTTP2.Stream.stream_id(),
          Plug.Conn.headers(),
          boolean(),
          ThousandIsland.Socket.t(),
          t()
        ) :: t()
  def send_headers(stream_id, headers, end_stream, socket, connection) do
    with enc_headers <- Enum.map(headers, fn {key, value} -> {:store, key, value} end),
         {block, send_hpack_state} <- HPAX.encode(enc_headers, connection.send_hpack_state) do
      %Bandit.HTTP2.Frame.Headers{
        stream_id: stream_id,
        end_stream: end_stream,
        fragment: block
      }
      |> send_frame(socket, connection)

      %{connection | send_hpack_state: send_hpack_state}
    end
  end

  @spec send_data(
          Bandit.HTTP2.Stream.stream_id(),
          iodata(),
          boolean(),
          fun(),
          ThousandIsland.Socket.t(),
          t()
        ) :: t()
  def send_data(stream_id, data, end_stream, on_unblock, socket, connection) do
    with connection_window_size <- connection.send_window_size,
         max_bytes_to_send <- max(connection_window_size, 0),
         {data_to_send, bytes_to_send, rest} <- split_data(data, max_bytes_to_send),
         connection <- %{connection | send_window_size: connection_window_size - bytes_to_send},
         end_stream_to_send <- end_stream && byte_size(rest) == 0 do
      if end_stream_to_send || bytes_to_send > 0 do
        %Bandit.HTTP2.Frame.Data{
          stream_id: stream_id,
          end_stream: end_stream_to_send,
          data: data_to_send
        }
        |> send_frame(socket, connection)
      end

      if byte_size(rest) == 0 do
        on_unblock.()
        connection
      else
        pending_sends = [{stream_id, rest, end_stream, on_unblock} | connection.pending_sends]
        %{connection | pending_sends: pending_sends}
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

  @spec send_recv_window_update(
          Bandit.HTTP2.Stream.stream_id(),
          non_neg_integer(),
          ThousandIsland.Socket.t(),
          t()
        ) :: term()
  def send_recv_window_update(stream_id, size_increment, socket, connection) do
    %Bandit.HTTP2.Frame.WindowUpdate{stream_id: stream_id, size_increment: size_increment}
    |> send_frame(socket, connection)
  end

  @spec send_rst_stream(
          Bandit.HTTP2.Stream.stream_id(),
          Bandit.HTTP2.Errors.error_code(),
          ThousandIsland.Socket.t(),
          t()
        ) :: term()
  def send_rst_stream(stream_id, error_code, socket, connection) do
    %Bandit.HTTP2.Frame.RstStream{stream_id: stream_id, error_code: error_code}
    |> send_frame(socket, connection)
  end

  @spec stream_terminated(pid(), t()) :: t()
  def stream_terminated(pid, connection) do
    %{connection | streams: Bandit.HTTP2.StreamCollection.delete(connection.streams, pid)}
  end

  #
  # Helper functions
  #

  @spec close_connection(Bandit.HTTP2.Errors.error_code(), term(), ThousandIsland.Socket.t(), t()) ::
          {:close, t()} | {:error, term(), t()}
  def close_connection(error_code, reason, socket, connection) do
    last_stream_id = Bandit.HTTP2.StreamCollection.last_stream_id(connection.streams)

    %Bandit.HTTP2.Frame.Goaway{last_stream_id: last_stream_id, error_code: error_code}
    |> send_frame(socket, connection)

    if error_code == Bandit.HTTP2.Errors.no_error(),
      do: {:close, connection},
      else: {:error, reason, connection}
  end

  @spec connection_error!(term()) :: no_return()
  @spec connection_error!(term(), Bandit.HTTP2.Errors.error_code()) :: no_return()
  defp connection_error!(message, error_code \\ Bandit.HTTP2.Errors.protocol_error()) do
    raise Bandit.HTTP2.Errors.ConnectionError, message: message, error_code: error_code
  end

  defp send_frame(frame, socket, connection) do
    _ =
      ThousandIsland.Socket.send(
        socket,
        Bandit.HTTP2.Frame.serialize(frame, connection.remote_settings.max_frame_size)
      )

    :ok
  end
end
