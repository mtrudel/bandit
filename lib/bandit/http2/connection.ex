defmodule Bandit.HTTP2.Connection do
  @moduledoc false
  # Represents the state of an HTTP/2 connection, in a process-free manner. An instance of this
  # struct is maintained as the state of a `Bandit.HTTP2.Handler` process, and it moves an HTTP/2
  # connection through its lifecycle by calling functions defined on this module

  require Logger

  # A stream blocked on the connection send window is bounded by the same 15s that already
  # bounds a block on the stream send window (`Bandit.HTTP2.Stream`'s `read_timeout`), so that
  # neither path can pin a stream process (and any resources it holds) indefinitely. The bound
  # is progress-based rather than being reset by every window update; see
  # `Bandit.HTTP2.FlowControl.extend_send_deadline/4`
  @pending_send_timeout 15_000

  # The largest HPACK encoder table we will keep, regardless of what the peer's
  # SETTINGS_HEADER_TABLE_SIZE permits. The peer controls that setting, so honoring it unchecked
  # lets a peer make us retain up to 4GiB of response headers per connection (RFC9113§6.5.2 and
  # RFC7541§4.2 both allow the encoder to use a smaller table than the decoder permits)
  @max_send_header_table_size 4_096

  # A stream consumes the messages we send it (DATA, HEADERS, WINDOW_UPDATE and so on) only when it
  # reads from us, so a stream which is busy elsewhere (in its plug, or blocked on a send window)
  # lets them pile up in its mailbox. Frames such as tiny DATA frames, WINDOW_UPDATEs and SETTINGS
  # cost a peer next to nothing to send, and each message costs us a few hundred bytes. Streams
  # report what they have consumed via `stream_messages_consumed/4`, and we bound what is
  # outstanding in two ways:
  #
  # * Once a stream has `@max_unbuffered_stream_messages` messages outstanding, we buffer further
  #   DATA here and send it as one message once the stream catches up. The buffer is a binary, so
  #   it costs about a byte for each byte of DATA, and the stream's receive window bounds it
  # * A stream which reaches `@max_queued_stream_messages` outstanding messages (which only other
  #   frame types can now cause) is reset with ENHANCE_YOUR_CALM
  @max_unbuffered_stream_messages 16
  @max_queued_stream_messages 100

  # The most non-ACK SETTINGS frames we will accept in a given period (in ms). Each one costs us
  # an ACK, and possibly a message to every stream
  @max_settings_rate {100, 10_000}

  # The connection receive window is returned to the peer as data arrives, so it does not bound
  # the data held by streams (the stream receive windows do that). We keep it to a fixed size
  # instead of the protocol maximum, so that we never advertise more than we will accept
  @recv_window_target 16_777_216

  defstruct local_settings: %Bandit.HTTP2.Settings{},
            remote_settings: %Bandit.HTTP2.Settings{},
            fragment_frame: nil,
            send_hpack_state: HPAX.new(4096),
            recv_hpack_state: HPAX.new(4096),
            send_window_size: 65_535,
            recv_window_size: 65_535,
            stream_recv_windows: %{},
            streams: %Bandit.HTTP2.StreamCollection{},
            # Set in init/3, since a :queue is opaque and so cannot be a compile-time default
            pending_sends: nil,
            pending_sends_expire_at: :infinity,
            stream_queued_messages: %{},
            stream_data_buffers: %{},
            remote_ended_streams: %{},
            conn_data: nil,
            telemetry_span: nil,
            plug: nil,
            opts: %{},
            reset_stream_timestamps: [],
            settings_timestamps: []

  @typedoc "Encapsulates the state of an HTTP/2 connection"
  @type t :: %__MODULE__{
          local_settings: Bandit.HTTP2.Settings.t(),
          remote_settings: Bandit.HTTP2.Settings.t(),
          fragment_frame: Bandit.HTTP2.Frame.Headers.t() | nil,
          send_hpack_state: term(),
          recv_hpack_state: term(),
          send_window_size: non_neg_integer(),
          recv_window_size: non_neg_integer(),
          stream_recv_windows: %{Bandit.HTTP2.Stream.stream_id() => integer() | :reset},
          streams: Bandit.HTTP2.StreamCollection.t(),
          pending_sends:
            :queue.queue({Bandit.HTTP2.Stream.stream_id(), iodata(), boolean(), fun(), integer()}),
          pending_sends_expire_at: integer() | :infinity,
          stream_queued_messages: %{Bandit.HTTP2.Stream.stream_id() => non_neg_integer()},
          stream_data_buffers: %{
            Bandit.HTTP2.Stream.stream_id() =>
              {binary(), non_neg_integer(),
               nil | :end_stream | {:headers, Plug.Conn.headers(), boolean()}}
          },
          remote_ended_streams: %{Bandit.HTTP2.Stream.stream_id() => true},
          conn_data: Bandit.Pipeline.conn_data(),
          telemetry_span: ThousandIsland.Telemetry.t(),
          plug: Bandit.Pipeline.plug_def(),
          opts: %{
            required(:http) => Bandit.http_options(),
            required(:http_2) => Bandit.http_2_options()
          },
          reset_stream_timestamps: [integer()],
          settings_timestamps: [integer()]
        }

  @spec init(ThousandIsland.Socket.t(), Bandit.Pipeline.plug_def(), map()) :: t()
  def init(socket, plug, opts) do
    connection = %__MODULE__{
      local_settings:
        struct!(Bandit.HTTP2.Settings, Keyword.get(opts.http_2, :default_local_settings, [])),
      pending_sends: :queue.new(),
      conn_data: Bandit.SocketHelpers.conn_data(socket),
      telemetry_span: ThousandIsland.Socket.telemetry_span(socket),
      plug: plug,
      opts: opts
    }

    # Send SETTINGS frame per RFC9113§3.4
    %Bandit.HTTP2.Frame.Settings{ack: false, settings: Map.from_struct(connection.local_settings)}
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
    connection = check_settings_rate_limit!(connection)
    %Bandit.HTTP2.Frame.Settings{ack: true} |> send_frame(socket, connection)

    # Merge whatever new settings were sent with our existing remote settings
    remote_settings = struct(connection.remote_settings, frame.settings)

    send_hpack_state =
      HPAX.resize(
        connection.send_hpack_state,
        min(remote_settings.header_table_size, @max_send_header_table_size)
      )

    delta = remote_settings.initial_window_size - connection.remote_settings.initial_window_size

    connection = %{
      connection
      | remote_settings: remote_settings,
        send_hpack_state: send_hpack_state
    }

    # A SETTINGS frame which does not change the window has nothing to tell the streams. A
    # SETTINGS frame never changes the connection send window, so pending sends cannot progress
    if delta != 0 do
      Bandit.HTTP2.StreamCollection.get_streams(connection.streams)
      |> Enum.reduce(connection, fn {stream_id, pid}, connection ->
        deliver_to_stream(
          connection,
          stream_id,
          pid,
          &Bandit.HTTP2.Stream.deliver_send_window_update(&1, delta),
          socket
        )
      end)
    else
      connection
    end
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

  def handle_frame(%Bandit.HTTP2.Frame.WindowUpdate{} = frame, socket, connection) do
    check_not_idle!(connection, frame.stream_id, "WINDOW_UPDATE")

    with_stream(
      connection,
      frame.stream_id,
      &Bandit.HTTP2.Stream.deliver_send_window_update(&1, frame.size_increment),
      socket
    )
  end

  def handle_frame(%Bandit.HTTP2.Frame.Headers{end_headers: true} = frame, socket, connection) do
    check_oversize_fragment!(frame.fragment, connection)

    case HPAX.decode(frame.fragment, connection.recv_hpack_state) do
      {:ok, headers, recv_hpack_state} ->
        # We need to preserve HPAX's internal state even if we reject this stream's header list
        connection = %{connection | recv_hpack_state: recv_hpack_state}

        deliver_headers(connection, frame, headers, socket)

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
    # Padding counts toward flow control just as data does (RFC9113§6.1)
    size = byte_size(frame.data) + frame.padding

    if Bandit.HTTP2.StreamCollection.get_pid(connection.streams, frame.stream_id) == :invalid,
      do: connection_error!("Received invalid stream identifier")

    check_not_idle!(connection, frame.stream_id, "DATA")

    # The connection window is debited by every DATA frame, whether or not its stream accepts it
    # (RFC9113§6.9.1). A peer which overruns it has broken flow control (RFC9113§6.9)
    if size > connection.recv_window_size do
      connection_error!(
        "DATA exceeds the connection receive window (RFC9113§6.9)",
        Bandit.HTTP2.Errors.flow_control_error()
      )
    end

    {recv_window_size, window_increment} =
      Bandit.HTTP2.FlowControl.compute_recv_window(
        connection.recv_window_size,
        size,
        @recv_window_target
      )

    if window_increment > 0 do
      %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 0, size_increment: window_increment}
      |> send_frame(socket, connection)
    end

    connection = %{connection | recv_window_size: recv_window_size}
    deliver_data(connection, frame, size, socket)
  end

  def handle_frame(%Bandit.HTTP2.Frame.Priority{}, _socket, connection), do: connection

  def handle_frame(%Bandit.HTTP2.Frame.RstStream{} = frame, _socket, connection) do
    # A stream blocked sending on the connection window is stuck inside a synchronous call to
    # this connection process, so it cannot itself observe the message that deliver_rst_stream/2
    # sends below; explicitly release any pending send for this stream so RST_STREAM actually
    # frees the resources it pins instead of being silently queued until the block eventually
    # clears (or never does).
    check_not_idle!(connection, frame.stream_id, "RST_STREAM")

    connection =
      purge_pending_send(connection, frame.stream_id, {:error, {:rst_stream, frame.error_code}})

    # Not subject to the stream's message limit, since we must not answer a RST_STREAM with one of
    # our own (RFC9113§5.4.2). The reset rate limit bounds these instead
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, frame.stream_id) do
      :invalid -> connection_error!("Received invalid stream identifier")
      stream -> Bandit.HTTP2.Stream.deliver_rst_stream(stream, frame.error_code)
    end

    check_reset_stream_rate_limit!(connection)
  end

  # Catch-all handler for unknown frame types

  def handle_frame(%Bandit.HTTP2.Frame.Unknown{} = frame, _socket, connection) do
    Logger.warning("Unknown frame (#{inspect(Map.from_struct(frame))})",
      domain: [:bandit],
      plug: connection.plug
    )

    connection
  end

  # Delivers DATA to its stream, enforcing the stream's receive window. A stream only regains
  # window once it has consumed data (see `send_recv_window_update/4`), so this bounds the data
  # which can queue up unread in the stream's mailbox, even while the stream is blocked sending
  defp deliver_data(connection, frame, size, socket) do
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, frame.stream_id) do
      pid when is_pid(pid) ->
        # A stream with no entry has not yet received any data
        window =
          Map.get(
            connection.stream_recv_windows,
            frame.stream_id,
            connection.local_settings.initial_window_size
          )

        cond do
          # Already reset for overrunning its window; discard anything which was in flight
          window == :reset ->
            connection

          remote_ended?(connection, frame.stream_id) ->
            close_ended_stream(connection, frame.stream_id, pid, socket)

          size > window ->
            overrun_stream_recv_window(connection, frame.stream_id, pid, socket)

          # A frame with no data, no padding and no END_STREAM has nothing to tell the stream
          size == 0 and not frame.end_stream ->
            connection

          true ->
            connection
            |> put_stream_recv_window(frame.stream_id, window - size)
            |> put_remote_ended(frame)
            |> queue_data(frame, pid, socket)
        end

      _closed ->
        connection
    end
  end

  defp overrun_stream_recv_window(connection, stream_id, pid, socket),
    do: reset_stream(connection, stream_id, pid, Bandit.HTTP2.Errors.flow_control_error(), socket)

  # Resets a stream on our own account. Anything the peer sends on it afterwards is discarded
  defp reset_stream(connection, stream_id, pid, error_code, socket) do
    send_rst_stream(stream_id, error_code, socket, connection)

    connection =
      purge_pending_send(connection, stream_id, {:error, {:rst_stream, error_code}})

    Bandit.HTTP2.Stream.deliver_rst_stream(pid, error_code)

    %{
      connection
      | stream_data_buffers: Map.delete(connection.stream_data_buffers, stream_id),
        remote_ended_streams: Map.delete(connection.remote_ended_streams, stream_id)
    }
    |> put_stream_recv_window(stream_id, :reset)
  end

  # Per RFC9113§5.1, a stream which the peer has ended can receive only WINDOW_UPDATE, PRIORITY and
  # RST_STREAM frames. The stream does not read anything else, so we must not queue it there
  defp remote_ended?(connection, stream_id),
    do: Map.has_key?(connection.remote_ended_streams, stream_id)

  defp put_remote_ended(connection, %{end_stream: true, stream_id: stream_id}) do
    # Only track live streams, since stream_terminated/2 removes the entry
    if is_pid(Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id)) do
      %{
        connection
        | remote_ended_streams: Map.put(connection.remote_ended_streams, stream_id, true)
      }
    else
      connection
    end
  end

  defp put_remote_ended(connection, _frame), do: connection

  defp close_ended_stream(connection, stream_id, pid, socket),
    do: reset_stream(connection, stream_id, pid, Bandit.HTTP2.Errors.stream_closed(), socket)

  # Sends DATA to the stream, or buffers it if the stream already has enough outstanding messages
  # (see `@max_unbuffered_stream_messages`). Once DATA is buffered, anything after it must be too
  defp queue_data(connection, frame, pid, socket) do
    tail = if frame.end_stream, do: :end_stream

    case Map.fetch(connection.stream_data_buffers, frame.stream_id) do
      {:ok, {data, padding, nil}} ->
        buffer = {<<data::binary, frame.data::binary>>, padding + frame.padding, tail}
        put_data_buffer(connection, frame.stream_id, buffer)

      # The peer has already ended the stream, so there can be nothing valid after it
      {:ok, _ended} ->
        connection

      :error ->
        if queued_messages(connection, frame.stream_id) < @max_unbuffered_stream_messages do
          deliver_to_stream(
            connection,
            frame.stream_id,
            pid,
            &Bandit.HTTP2.Stream.deliver_data(&1, frame.data, frame.padding, frame.end_stream),
            socket
          )
        else
          # Copy the data, so that the buffer does not keep the whole received binary alive
          buffer = {:binary.copy(frame.data), frame.padding, tail}
          put_data_buffer(connection, frame.stream_id, buffer)
        end
    end
  end

  defp put_data_buffer(connection, stream_id, buffer),
    do: %{
      connection
      | stream_data_buffers: Map.put(connection.stream_data_buffers, stream_id, buffer)
    }

  defp flush_data_buffer(connection, stream_id, socket) do
    with {:ok, {data, padding, tail}} <- Map.fetch(connection.stream_data_buffers, stream_id),
         true <- queued_messages(connection, stream_id) < @max_unbuffered_stream_messages,
         pid when is_pid(pid) <-
           Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id) do
      connection = %{
        connection
        | stream_data_buffers: Map.delete(connection.stream_data_buffers, stream_id)
      }

      end_stream = tail == :end_stream

      connection =
        if data != <<>> or padding > 0 or end_stream do
          deliver_to_stream(
            connection,
            stream_id,
            pid,
            &Bandit.HTTP2.Stream.deliver_data(&1, data, padding, end_stream),
            socket
          )
        else
          connection
        end

      case tail do
        {:headers, headers, end_stream} ->
          deliver_to_stream(
            connection,
            stream_id,
            pid,
            &Bandit.HTTP2.Stream.deliver_headers(&1, headers, end_stream),
            socket
          )

        _ ->
          connection
      end
    else
      _ -> connection
    end
  end

  defp put_stream_recv_window(connection, stream_id, window),
    do: %{
      connection
      | stream_recv_windows: Map.put(connection.stream_recv_windows, stream_id, window)
    }

  # A stream error raised while opening the stream must not discard the HPACK state we have just
  # advanced by decoding this header block; if it did, our decoder would no longer match the
  # peer's encoder for the rest of the connection
  defp deliver_headers(connection, frame, headers, socket) do
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, frame.stream_id) do
      :invalid ->
        connection_error!("Received invalid stream identifier")

      :closed ->
        :ok

      _stream ->
        # Erlang term ordering does the right thing with :infinity here
        if header_list_size(headers) > connection.local_settings.max_header_list_size do
          stream_error!(
            "Decoded header list exceeds max_header_list_size (RFC9113§6.5.2)",
            frame.stream_id,
            Bandit.HTTP2.Errors.enhance_your_calm()
          )
        end
    end

    case Map.fetch(connection.stream_data_buffers, frame.stream_id) do
      _ when is_map_key(connection.remote_ended_streams, frame.stream_id) ->
        pid = Bandit.HTTP2.StreamCollection.get_pid(connection.streams, frame.stream_id)
        close_ended_stream(connection, frame.stream_id, pid, socket)

      # Trailers must reach the stream after the DATA we have buffered for it
      {:ok, {data, padding, nil}} ->
        buffer = {data, padding, {:headers, headers, frame.end_stream}}
        connection |> put_data_buffer(frame.stream_id, buffer) |> put_remote_ended(frame)

      {:ok, _ended} ->
        connection

      :error ->
        connection
        |> with_stream(
          frame.stream_id,
          &Bandit.HTTP2.Stream.deliver_headers(&1, headers, frame.end_stream),
          socket
        )
        |> put_remote_ended(frame)
    end
  rescue
    error in Bandit.HTTP2.Errors.StreamError ->
      case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, error.stream_id) do
        pid when is_pid(pid) ->
          reset_stream(connection, error.stream_id, pid, error.error_code, socket)

        _stream ->
          send_rst_stream(error.stream_id, error.error_code, socket, connection)

          # Record the refused stream as seen, so that the peer cannot open it again later
          %{
            connection
            | streams: Bandit.HTTP2.StreamCollection.refuse(connection.streams, error.stream_id)
          }
      end
  end

  # Per RFC9113§5.1, an idle stream can receive only HEADERS and PRIORITY frames
  defp check_not_idle!(connection, stream_id, frame_type) do
    if Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id) == :new,
      do: connection_error!("Received #{frame_type} in idle state")
  end

  # See `@max_queued_stream_messages`
  defp deliver_to_stream(connection, stream_id, pid, fun, socket) do
    queued = queued_messages(connection, stream_id)

    cond do
      Map.get(connection.stream_recv_windows, stream_id) == :reset ->
        connection

      queued >= @max_queued_stream_messages ->
        reset_stream(connection, stream_id, pid, Bandit.HTTP2.Errors.enhance_your_calm(), socket)

      true ->
        fun.(pid)

        %{
          connection
          | stream_queued_messages:
              Map.put(connection.stream_queued_messages, stream_id, queued + 1)
        }
    end
  end

  defp queued_messages(connection, stream_id),
    do: Map.get(connection.stream_queued_messages, stream_id, 0)

  @spec stream_messages_consumed(
          Bandit.HTTP2.Stream.stream_id(),
          non_neg_integer(),
          ThousandIsland.Socket.t(),
          t()
        ) :: t()
  def stream_messages_consumed(stream_id, count, socket, connection) do
    case Map.fetch(connection.stream_queued_messages, stream_id) do
      {:ok, queued} ->
        %{
          connection
          | stream_queued_messages:
              Map.put(connection.stream_queued_messages, stream_id, max(queued - count, 0))
        }
        |> flush_data_buffer(stream_id, socket)

      :error ->
        connection
    end
  end

  defp with_stream(connection, stream_id, fun, socket) do
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id) do
      pid when is_pid(pid) ->
        deliver_to_stream(connection, stream_id, pid, fun, socket)

      :closed ->
        connection

      :new ->
        new_stream!(connection, stream_id)

        sendfile_chunk_size =
          Keyword.get(connection.opts.http_2, :sendfile_chunk_size, 1_048_576)

        stream =
          Bandit.HTTP2.Stream.init(
            self(),
            stream_id,
            connection.remote_settings.initial_window_size,
            connection.local_settings.initial_window_size,
            sendfile_chunk_size
          )

        case Bandit.HTTP2.StreamProcess.start_link(
               stream,
               connection.plug,
               connection.telemetry_span,
               connection.conn_data,
               connection.opts
             ) do
          {:ok, pid} ->
            streams = Bandit.HTTP2.StreamCollection.insert(connection.streams, stream_id, pid)
            with_stream(%{connection | streams: streams}, stream_id, fun, socket)

          _ ->
            raise "Unable to start stream process"
        end

      :invalid ->
        connection_error!("Received invalid stream identifier")
    end
  end

  defp new_stream!(connection, stream_id) do
    max_requests = Keyword.get(connection.opts.http_2, :max_requests, 0)

    if max_requests != 0 and
         max_requests <= Bandit.HTTP2.StreamCollection.stream_count(connection.streams) do
      connection_error!("Connection count exceeded", Bandit.HTTP2.Errors.refused_stream())
    end

    # Erlang term ordering does the right thing with :infinity here
    if connection.local_settings.max_concurrent_streams <=
         Bandit.HTTP2.StreamCollection.open_stream_count(connection.streams) do
      stream_error!(
        "Concurrent stream count exceeded",
        stream_id,
        Bandit.HTTP2.Errors.refused_stream()
      )
    end
  end

  defp check_oversize_fragment!(fragment, connection) do
    if byte_size(fragment) > Keyword.get(connection.opts.http_2, :max_header_block_size, 50_000),
      do: connection_error!("Received overlong headers")
  end

  # Header list size per RFC9113§6.5.2
  defp header_list_size(headers) do
    Enum.reduce(headers, 0, fn {name, value}, acc ->
      acc + byte_size(name) + byte_size(value) + 32
    end)
  end

  @spec check_reset_stream_rate_limit!(t()) :: t()
  defp check_reset_stream_rate_limit!(connection) do
    case Keyword.get(connection.opts.http_2, :max_reset_stream_rate, {500, 10_000}) do
      nil ->
        connection

      {intensity, period} ->
        timestamps =
          check_rate_limit!(
            connection.reset_stream_timestamps,
            intensity,
            period,
            "Stream resets rate exceeded #{intensity} resets in #{period}ms"
          )

        %{connection | reset_stream_timestamps: timestamps}
    end
  end

  @spec check_settings_rate_limit!(t()) :: t()
  defp check_settings_rate_limit!(connection) do
    {intensity, period} = @max_settings_rate

    timestamps =
      check_rate_limit!(
        connection.settings_timestamps,
        intensity,
        period,
        "SETTINGS rate exceeded #{intensity} frames in #{period}ms"
      )

    %{connection | settings_timestamps: timestamps}
  end

  # Records an event against `timestamps` (newest first), raising if this makes for more than
  # `intensity` events in the last `period` ms
  defp check_rate_limit!(timestamps, intensity, period, message) do
    now = :erlang.monotonic_time(:millisecond)
    [now | prune_timestamps(intensity - 1, now - period, timestamps, [], message)]
  end

  defp prune_timestamps(_, _, [], acc, _),
    do: :lists.reverse(acc)

  defp prune_timestamps(_, threshold, [timestamp | _], acc, _) when timestamp < threshold,
    do: :lists.reverse(acc)

  defp prune_timestamps(0, _, [_ | _], _acc, message),
    do: connection_error!(message, Bandit.HTTP2.Errors.enhance_your_calm())

  defp prune_timestamps(n, threshold, [timestamp | timestamps], acc, message),
    do: prune_timestamps(n - 1, threshold, timestamps, [timestamp | acc], message)

  # Shared logic to send any pending frames upon adjustment of our send window. Sends go in the
  # order they were queued, and we stop once the window is used up, so that a small window
  # increment costs work only for the sends it can actually progress
  defp do_pending_sends(socket, connection) do
    if connection.send_window_size > 0 do
      case :queue.out(connection.pending_sends) do
        {{:value, pending_send}, pending_sends} ->
          {stream_id, rest, end_stream, on_unblock, expires_at} = pending_send
          connection = %{connection | pending_sends: pending_sends}

          connection =
            do_send_data(
              stream_id,
              [],
              rest,
              end_stream,
              on_unblock,
              expires_at,
              socket,
              connection
            )

          do_pending_sends(socket, connection)

        {:empty, _} ->
          connection
      end
    else
      connection
    end
  end

  # Releases a queued pending send for `stream_id` (if any), replying to its blocked caller with
  # `reply` instead of leaving it to be written later against a stream that may no longer exist.
  @spec purge_pending_send(t(), Bandit.HTTP2.Stream.stream_id(), term()) :: t()
  defp purge_pending_send(connection, stream_id, reply) do
    {purged, pending_sends} =
      connection.pending_sends
      |> :queue.to_list()
      |> Enum.split_with(&(elem(&1, 0) == stream_id))

    case purged do
      [] ->
        connection

      purged ->
        Enum.each(purged, fn {_stream_id, _rest, _end_stream, on_unblock, _expires_at} ->
          on_unblock.(reply)
        end)

        %{connection | pending_sends: :queue.from_list(pending_sends)}
    end
  end

  # Bounds how long a send can sit in pending_sends waiting on the connection send window. Called
  # whenever data arrives on the connection (see `Bandit.HTTP2.Handler.handle_data/3`), so a
  # client that only ever sends keepalive PINGs (defeating the transport-level read timeout)
  # cannot pin a blocked stream's process, Plug state, and any resources it holds indefinitely.
  #
  # `pending_sends_expire_at` is never later than the earliest deadline in pending_sends (deadlines
  # only ever move later), so we need only scan the queue once it has passed
  @spec expire_pending_sends(t()) :: t()
  def expire_pending_sends(connection) do
    now = :erlang.monotonic_time(:millisecond)

    if connection.pending_sends_expire_at <= now do
      {expired, live} =
        connection.pending_sends
        |> :queue.to_list()
        |> Enum.split_with(fn {_, _, _, _, expires_at} -> expires_at <= now end)

      Enum.each(expired, fn {_stream_id, _rest, _end_stream, on_unblock, _expires_at} ->
        on_unblock.({:error, :timeout})
      end)

      expire_at =
        Enum.reduce(live, :infinity, fn {_, _, _, _, expires_at}, acc -> min(expires_at, acc) end)

      %{connection | pending_sends: :queue.from_list(live), pending_sends_expire_at: expire_at}
    else
      connection
    end
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
    {headers_iodata, connection} = encode_headers(stream_id, headers, end_stream, connection)
    ThousandIsland.Socket.send(socket, headers_iodata)
    connection
  end

  # Sends `data` for a stream, optionally coalescing a leading HEADERS frame (when `headers` is
  # non-empty) into the same socket write. HEADERS are not flow-controlled; only the DATA obeys the
  # connection send window, with any remainder queued in pending_sends.
  @spec send_data(
          Bandit.HTTP2.Stream.stream_id(),
          Plug.Conn.headers(),
          iodata(),
          boolean(),
          fun(),
          ThousandIsland.Socket.t(),
          t()
        ) :: t()
  def send_data(stream_id, headers, data, end_stream, on_unblock, socket, connection),
    do: do_send_data(stream_id, headers, data, end_stream, on_unblock, nil, socket, connection)

  # `expires_at` is the deadline of a send which has already been queued, or nil for a new send
  defp do_send_data(
         stream_id,
         headers,
         data,
         end_stream,
         on_unblock,
         expires_at,
         socket,
         connection
       ) do
    {prefix_iodata, connection} =
      if headers == [],
        do: {[], connection},
        else: encode_headers(stream_id, headers, false, connection)

    {data_iodata, rest, bytes_sent, connection} =
      split_window(stream_id, data, end_stream, connection)

    if !Bandit.SocketHelpers.iodata_empty?(prefix_iodata) ||
         !Bandit.SocketHelpers.iodata_empty?(data_iodata) do
      ThousandIsland.Socket.send(socket, [prefix_iodata, data_iodata])
    end

    finish_data(stream_id, rest, end_stream, on_unblock, expires_at, bytes_sent, connection)
  end

  defp encode_headers(stream_id, headers, end_stream, connection) do
    enc_headers = Enum.map(headers, fn {key, value} -> {:store, key, value} end)
    {block, send_hpack_state} = HPAX.encode(enc_headers, connection.send_hpack_state)

    iodata =
      serialize_frame(
        %Bandit.HTTP2.Frame.Headers{
          stream_id: stream_id,
          end_stream: end_stream,
          fragment: block
        },
        connection
      )

    {iodata, %{connection | send_hpack_state: send_hpack_state}}
  end

  defp split_window(stream_id, data, end_stream, connection) do
    max_bytes_to_send = max(connection.send_window_size, 0)
    {data_to_send, bytes_to_send, rest} = split_data(data, max_bytes_to_send)
    connection = %{connection | send_window_size: connection.send_window_size - bytes_to_send}
    end_stream_to_send = end_stream && byte_size(rest) == 0

    iodata =
      if end_stream_to_send || bytes_to_send > 0 do
        serialize_frame(
          %Bandit.HTTP2.Frame.Data{
            stream_id: stream_id,
            end_stream: end_stream_to_send,
            data: data_to_send
          },
          connection
        )
      else
        []
      end

    {iodata, rest, bytes_to_send, connection}
  end

  defp finish_data(_stream_id, <<>>, _end_stream, on_unblock, _expires_at, _bytes_sent, conn) do
    on_unblock.(:ok)
    conn
  end

  defp finish_data(stream_id, rest, end_stream, on_unblock, expires_at, bytes_sent, connection) do
    now = :erlang.monotonic_time(:millisecond)

    # Only a send which is being re-queued after making (some) progress has a deadline to extend;
    # a send which is blocking for the first time gets a fresh one
    expires_at =
      if expires_at do
        Bandit.HTTP2.FlowControl.extend_send_deadline(
          expires_at,
          bytes_sent,
          now,
          @pending_send_timeout
        )
      else
        now + @pending_send_timeout
      end

    pending_sends =
      :queue.in({stream_id, rest, end_stream, on_unblock, expires_at}, connection.pending_sends)

    %{
      connection
      | pending_sends: pending_sends,
        pending_sends_expire_at: min(connection.pending_sends_expire_at, expires_at)
    }
  end

  defp split_data(data, desired_length) do
    data_length = IO.iodata_length(data)

    if data_length <= desired_length do
      {data, data_length, <<>>}
    else
      <<to_send::binary-size(^desired_length), rest::binary>> = IO.iodata_to_binary(data)
      {to_send, desired_length, rest}
    end
  end

  @spec send_recv_window_update(
          Bandit.HTTP2.Stream.stream_id(),
          non_neg_integer(),
          ThousandIsland.Socket.t(),
          t()
        ) :: t()
  def send_recv_window_update(stream_id, size_increment, socket, connection) do
    %Bandit.HTTP2.Frame.WindowUpdate{stream_id: stream_id, size_increment: size_increment}
    |> send_frame(socket, connection)

    # The stream sends this once it has consumed data, which is what gives window back to the peer
    case Map.fetch(connection.stream_recv_windows, stream_id) do
      {:ok, window} when is_integer(window) ->
        put_stream_recv_window(connection, stream_id, window + size_increment)

      _ ->
        connection
    end
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

  @spec stream_terminated(pid(), term(), ThousandIsland.Socket.t(), t()) :: t()
  def stream_terminated(pid, reason, socket, connection) do
    case Bandit.HTTP2.StreamCollection.get_stream_id(connection.streams, pid) do
      nil ->
        connection

      stream_id ->
        # If this stream had a pending send queued, its process is by definition the one that
        # just exited, so purge the bytes before they can be written against a dead stream. The
        # reply value is never observed.
        connection = purge_pending_send(connection, stream_id, {:error, :closed})

        if reason != :normal do
          # A process can exit just after sending END_STREAM, so this reset may race with a
          # completed stream. Sending it is harmless; it also prevents clients waiting forever
          # when a stream exits abnormally before END_STREAM.
          send_rst_stream(stream_id, Bandit.HTTP2.Errors.internal_error(), socket, connection)
        end

        %{
          connection
          | streams: Bandit.HTTP2.StreamCollection.delete(connection.streams, pid),
            stream_recv_windows: Map.delete(connection.stream_recv_windows, stream_id),
            stream_queued_messages: Map.delete(connection.stream_queued_messages, stream_id),
            stream_data_buffers: Map.delete(connection.stream_data_buffers, stream_id),
            remote_ended_streams: Map.delete(connection.remote_ended_streams, stream_id)
        }
    end
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

  @spec stream_error!(
          String.t(),
          Bandit.HTTP2.Stream.stream_id(),
          Bandit.HTTP2.Errors.error_code()
        ) ::
          no_return()
  defp stream_error!(message, stream_id, error_code) do
    raise Bandit.HTTP2.Errors.StreamError,
      message: message,
      error_code: error_code,
      stream_id: stream_id
  end

  defp send_frame(frame, socket, connection) do
    ThousandIsland.Socket.send(socket, serialize_frame(frame, connection))
  end

  defp serialize_frame(frame, connection),
    do: Bandit.HTTP2.Frame.serialize(frame, connection.remote_settings.max_frame_size)
end
