defmodule Bandit.HTTP2.Connection do
  @moduledoc false
  # Represents the state of an HTTP/2 connection, in a process-free manner. An instance of this
  # struct is maintained as the state of a `Bandit.HTTP2.Handler` process, and it moves an HTTP/2
  # connection through its lifecycle by calling functions defined on this module

  require Logger

  # A stream blocked on the connection send window is bounded by the same 15s that already
  # bounds a block on the stream send window (`Bandit.HTTP2.Stream`'s `read_timeout`), so that
  # neither path can pin a stream process (and any resources it holds) indefinitely.
  @pending_send_timeout 15_000

  defstruct local_settings: %Bandit.HTTP2.Settings{},
            remote_settings: %Bandit.HTTP2.Settings{},
            fragment_frame: nil,
            send_hpack_state: HPAX.new(4096),
            recv_hpack_state: HPAX.new(4096),
            send_window_size: 65_535,
            recv_window_size: 65_535,
            streams: %Bandit.HTTP2.StreamCollection{},
            pending_sends: [],
            conn_data: nil,
            telemetry_span: nil,
            plug: nil,
            opts: %{},
            reset_stream_timestamps: []

  @typedoc "Encapsulates the state of an HTTP/2 connection"
  @type t :: %__MODULE__{
          local_settings: Bandit.HTTP2.Settings.t(),
          remote_settings: Bandit.HTTP2.Settings.t(),
          fragment_frame: Bandit.HTTP2.Frame.Headers.t() | nil,
          send_hpack_state: term(),
          recv_hpack_state: term(),
          send_window_size: non_neg_integer(),
          recv_window_size: non_neg_integer(),
          streams: Bandit.HTTP2.StreamCollection.t(),
          pending_sends: [
            {Bandit.HTTP2.Stream.stream_id(), iodata(), boolean(), fun(), integer()}
          ],
          conn_data: Bandit.Pipeline.conn_data(),
          telemetry_span: ThousandIsland.Telemetry.t(),
          plug: Bandit.Pipeline.plug_def(),
          opts: %{
            required(:http) => Bandit.http_options(),
            required(:http_2) => Bandit.http_2_options()
          },
          reset_stream_timestamps: [integer()]
        }

  @spec init(ThousandIsland.Socket.t(), Bandit.Pipeline.plug_def(), map()) :: t()
  def init(socket, plug, opts) do
    connection = %__MODULE__{
      local_settings:
        struct!(Bandit.HTTP2.Settings, Keyword.get(opts.http_2, :default_local_settings, [])),
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
    %Bandit.HTTP2.Frame.Settings{ack: true} |> send_frame(socket, connection)

    # Merge whatever new settings were sent with our existing remote settings
    remote_settings = struct(connection.remote_settings, frame.settings)

    send_hpack_state = HPAX.resize(connection.send_hpack_state, remote_settings.header_table_size)
    delta = remote_settings.initial_window_size - connection.remote_settings.initial_window_size

    Bandit.HTTP2.StreamCollection.get_pids(connection.streams)
    |> Enum.each(&Bandit.HTTP2.Stream.deliver_send_window_update(&1, delta))

    do_pending_sends(socket, %{
      connection
      | remote_settings: remote_settings,
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

  def handle_frame(%Bandit.HTTP2.Frame.Headers{end_headers: true} = frame, socket, connection) do
    check_oversize_fragment!(frame.fragment, connection)

    case HPAX.decode(frame.fragment, connection.recv_hpack_state) do
      {:ok, headers, recv_hpack_state} ->
        # We need to preserve HPAX's internal state even if we reject this stream's header list
        connection = %{connection | recv_hpack_state: recv_hpack_state}

        # Erlang term ordering does the right thing with :infinity here
        if header_list_size(headers) > connection.local_settings.max_header_list_size do
          send_rst_stream(
            frame.stream_id,
            Bandit.HTTP2.Errors.enhance_your_calm(),
            socket,
            connection
          )

          connection
        else
          streams =
            with_stream(connection, frame.stream_id, fn stream ->
              Bandit.HTTP2.Stream.deliver_headers(stream, headers, frame.end_stream)
            end)

          %{connection | streams: streams}
        end

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
    # A stream blocked sending on the connection window is stuck inside a synchronous call to
    # this connection process, so it cannot itself observe the message that deliver_rst_stream/2
    # sends below; explicitly release any pending send for this stream so RST_STREAM actually
    # frees the resources it pins instead of being silently queued until the block eventually
    # clears (or never does).
    connection =
      purge_pending_send(connection, frame.stream_id, {:error, {:rst_stream, frame.error_code}})

    streams =
      with_stream(connection, frame.stream_id, fn stream ->
        Bandit.HTTP2.Stream.deliver_rst_stream(stream, frame.error_code)
      end)

    %{connection | streams: streams}
    |> check_reset_stream_rate_limit!()
  end

  # Catch-all handler for unknown frame types

  def handle_frame(%Bandit.HTTP2.Frame.Unknown{} = frame, _socket, connection) do
    Logger.warning("Unknown frame (#{inspect(Map.from_struct(frame))})",
      domain: [:bandit],
      plug: connection.plug
    )

    connection
  end

  defp with_stream(connection, stream_id, fun) do
    case Bandit.HTTP2.StreamCollection.get_pid(connection.streams, stream_id) do
      pid when is_pid(pid) or pid == :closed ->
        fun.(pid)
        connection.streams

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
            with_stream(%{connection | streams: streams}, stream_id, fun)

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
      # drop the `|| ""` once we depend on a hpax release with elixir-mint/hpax#27,
      acc + byte_size(name) + byte_size(value || "") + 32
    end)
  end

  @spec check_reset_stream_rate_limit!(t()) :: t()
  defp check_reset_stream_rate_limit!(connection) do
    case Keyword.get(connection.opts.http_2, :max_reset_stream_rate, {500, 10_000}) do
      nil ->
        connection

      {intensity, period} ->
        now = :erlang.monotonic_time(:millisecond)
        threshold = now - period
        resets = connection.reset_stream_timestamps
        recent_timestamps = can_reset(intensity - 1, threshold, resets, [], intensity, period)
        %{connection | reset_stream_timestamps: [now | recent_timestamps]}
    end
  end

  defp can_reset(_, _, [], acc, _, _),
    do: :lists.reverse(acc)

  defp can_reset(_, threshold, [restart | _], acc, _, _) when restart < threshold,
    do: :lists.reverse(acc)

  defp can_reset(0, _, [_ | _], _acc, intensity, period),
    do:
      connection_error!(
        "Stream resets rate exceeded #{intensity} resets in #{period}ms",
        Bandit.HTTP2.Errors.enhance_your_calm()
      )

  defp can_reset(n, threshold, [restart | restarts], acc, intensity, period),
    do: can_reset(n - 1, threshold, restarts, [restart | acc], intensity, period)

  # Shared logic to send any pending frames upon adjustment of our send window
  defp do_pending_sends(socket, connection) do
    connection.pending_sends
    |> Enum.reverse()
    |> Enum.reduce(connection, fn pending_send, connection ->
      connection = connection |> Map.update!(:pending_sends, &List.delete(&1, pending_send))
      {stream_id, rest, end_stream, on_unblock, _expires_at} = pending_send
      send_data(stream_id, [], rest, end_stream, on_unblock, socket, connection)
    end)
  end

  # Releases a queued pending send for `stream_id` (if any), replying to its blocked caller with
  # `reply` instead of leaving it to be written later against a stream that may no longer exist.
  @spec purge_pending_send(t(), Bandit.HTTP2.Stream.stream_id(), term()) :: t()
  defp purge_pending_send(connection, stream_id, reply) do
    case List.keytake(connection.pending_sends, stream_id, 0) do
      nil ->
        connection

      {{_stream_id, _rest, _end_stream, on_unblock, _expires_at}, pending_sends} ->
        on_unblock.(reply)
        %{connection | pending_sends: pending_sends}
    end
  end

  # Bounds how long a send can sit in pending_sends waiting on the connection send window. Called
  # whenever data arrives on the connection (see `Bandit.HTTP2.Handler.handle_data/3`), so a
  # client that only ever sends keepalive PINGs (defeating the transport-level read timeout)
  # cannot pin a blocked stream's process, Plug state, and any resources it holds indefinitely.
  @spec expire_pending_sends(t()) :: t()
  def expire_pending_sends(connection) do
    now = :erlang.monotonic_time(:millisecond)

    {expired, live} =
      Enum.split_with(connection.pending_sends, fn {_, _, _, _, expires_at} ->
        expires_at <= now
      end)

    Enum.each(expired, fn {_stream_id, _rest, _end_stream, on_unblock, _expires_at} ->
      on_unblock.({:error, :timeout})
    end)

    %{connection | pending_sends: live}
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
  def send_data(stream_id, headers, data, end_stream, on_unblock, socket, connection) do
    {prefix_iodata, connection} =
      if headers == [],
        do: {[], connection},
        else: encode_headers(stream_id, headers, false, connection)

    {data_iodata, rest, connection} = split_window(stream_id, data, end_stream, connection)

    if !Bandit.SocketHelpers.iodata_empty?(prefix_iodata) ||
         !Bandit.SocketHelpers.iodata_empty?(data_iodata) do
      ThousandIsland.Socket.send(socket, [prefix_iodata, data_iodata])
    end

    finish_data(stream_id, rest, end_stream, on_unblock, connection)
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

    {iodata, rest, connection}
  end

  defp finish_data(_stream_id, <<>>, _end_stream, on_unblock, connection) do
    on_unblock.(:ok)
    connection
  end

  defp finish_data(stream_id, rest, end_stream, on_unblock, connection) do
    expires_at = :erlang.monotonic_time(:millisecond) + @pending_send_timeout

    pending_sends = [
      {stream_id, rest, end_stream, on_unblock, expires_at} | connection.pending_sends
    ]

    %{connection | pending_sends: pending_sends}
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
    # If this stream had a pending send queued, its process is by definition the one that just
    # exited (that's what an :EXIT for `pid` means), so there is no longer a live caller to hear
    # the reply; the purge here is only to drop the queued bytes so they can't be written later
    # against a stream nothing is running anymore. The reply value itself is never observed.
    connection =
      case Bandit.HTTP2.StreamCollection.get_stream_id(connection.streams, pid) do
        nil -> connection
        stream_id -> purge_pending_send(connection, stream_id, {:error, :closed})
      end

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
