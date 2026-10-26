defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, PerMessageDeflate, Socket}

  defstruct websock: nil,
            websock_state: nil,
            state: :open,
            compress: nil,
            opts: [],
            fragment_frame: nil,
            fragment_size: 0,
            fragment_pending: [],
            fragment_pending_count: 0,
            close_timeout: nil,
            close_timer_ref: nil,
            span: nil,
            metrics: %{}

  @typedoc "Connection state"
  @type state :: :open | :closing | :closed

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          websock: WebSock.impl(),
          websock_state: WebSock.state(),
          state: state(),
          compress: PerMessageDeflate.t() | nil,
          opts: keyword(),
          fragment_frame: Frame.Text.t() | Frame.Binary.t() | nil,
          fragment_size: non_neg_integer(),
          fragment_pending: iodata(),
          fragment_pending_count: non_neg_integer(),
          close_timeout: non_neg_integer() | nil,
          close_timer_ref: reference() | nil,
          span: Bandit.Telemetry.t(),
          metrics: map()
        }

  # The maximum number of non-final continuation frames that are kept as separate binaries before
  # they are copied into one binary. Each kept frame costs about 150 bytes of memory, whatever the
  # size of its payload, so a peer that sends 1 byte fragments could otherwise keep about 150x
  # max_fragmented_message_size in memory (GHSA-cpx7-qf6w-jc63). Each batch is copied one time
  # only, so reassembly stays linear in the size of the message (GHSA-vg8x-66vg-5pxh)
  @max_pending_fragments 1024

  # The close timeout to use when the connection has no finite timeout. A closing connection must
  # have a limit, or a silent peer (or one that sends a trickle of frames) could keep it open forever
  @default_close_timeout 60_000

  def init(websock, websock_state, connection_opts, socket) do
    compress = Keyword.get(connection_opts, :compress)

    connection_telemetry_span_context =
      ThousandIsland.Socket.telemetry_span(socket).telemetry_span_context

    span =
      Bandit.Telemetry.start_span(:websocket, %{compress: compress}, %{
        connection_telemetry_span_context: connection_telemetry_span_context,
        websock: websock
      })

    instance = %__MODULE__{
      websock: websock,
      websock_state: websock_state,
      compress: compress,
      opts: connection_opts,
      close_timeout: close_timeout(Keyword.get(connection_opts, :timeout) || socket.read_timeout),
      span: span
    }

    websock.init(websock_state) |> handle_continuation(socket, instance)
  end

  # Process.send_after/3 accepts timeouts up to 2^32 - 1 ms only
  defp close_timeout(timeout) when is_integer(timeout) and timeout in 0..4_294_967_295,
    do: timeout

  defp close_timeout(_timeout), do: @default_close_timeout

  # Recv metrics are recorded here and only here: dispatch_frame/3 re-enters itself with
  # synthesized frames (inflated payloads, reassembled fragmented messages) which never
  # arrived on the wire and so must not be counted a second time
  def handle_frame(frame, socket, %{state: :open} = connection),
    do: dispatch_frame(frame, socket, do_recv_metrics(frame, connection))

  # After we send a Close frame (RFC6455§7.1.2) the WebSock is terminated. Only the Close frame of
  # the peer is of interest now. Discard all other frames, so that they never get to the WebSock
  # (GHSA-2v5v-8f9v-xh85)
  def handle_frame(%Frame.ConnectionClose{} = frame, socket, connection),
    do: handle_control_frame(frame, socket, connection)

  def handle_frame(_frame, _socket, connection), do: {:continue, connection}

  defp dispatch_frame(frame, socket, %{fragment_frame: nil} = connection) do
    case frame do
      %Frame.Continuation{} ->
        do_error(1002, "Received unexpected continuation frame (RFC6455§5.4)", socket, connection)

      %Frame.Text{fin: true, compressed: true} = frame ->
        do_inflate(frame, socket, connection)

      %Frame.Text{fin: true} = frame ->
        if !Keyword.get(connection.opts, :validate_text_frames, true) || String.valid?(frame.data) do
          connection.websock.handle_in({frame.data, opcode: :text}, connection.websock_state)
          |> handle_continuation(socket, connection)
        else
          do_error(1007, "Received non UTF-8 text frame (RFC6455§8.1)", socket, connection)
        end

      %Frame.Text{fin: false} = frame ->
        {:continue,
         %{connection | fragment_frame: frame, fragment_size: IO.iodata_length(frame.data)}}

      %Frame.Binary{fin: true, compressed: true} = frame ->
        do_inflate(frame, socket, connection)

      %Frame.Binary{fin: true} = frame ->
        connection.websock.handle_in({frame.data, opcode: :binary}, connection.websock_state)
        |> handle_continuation(socket, connection)

      %Frame.Binary{fin: false} = frame ->
        {:continue,
         %{connection | fragment_frame: frame, fragment_size: IO.iodata_length(frame.data)}}

      frame ->
        handle_control_frame(frame, socket, connection)
    end
  end

  defp dispatch_frame(frame, socket, %{fragment_frame: fragment_frame} = connection)
       when not is_nil(fragment_frame) do
    case frame do
      %Frame.Continuation{fin: true} = frame ->
        fragment_size = connection.fragment_size + IO.iodata_length(frame.data)

        if oversize_message?(fragment_size, connection.opts) do
          do_error(1009, "Received oversize fragmented message", socket, connection)
        else
          data =
            IO.iodata_to_binary([
              connection.fragment_frame.data,
              connection.fragment_pending | frame.data
            ])

          frame = %{connection.fragment_frame | fin: true, data: data}
          dispatch_frame(frame, socket, clear_fragments(connection))
        end

      %Frame.Continuation{fin: false} = frame ->
        frame_size = IO.iodata_length(frame.data)

        if frame_size == 0 do
          # An empty non-final continuation is a legal no-op (RFC6455§5.4). It is deliberately
          # NOT appended to the accumulated fragments: retaining a list cell per empty frame
          # would let a peer grow fragment state without ever increasing fragment_size, which
          # is the growth max_fragmented_message_size bounds (GHSA-pf94-94m9-536p). Leaving
          # the connection untouched keeps that mitigation intact
          {:continue, connection}
        else
          fragment_size = connection.fragment_size + frame_size

          if oversize_message?(fragment_size, connection.opts) do
            do_error(1009, "Received oversize fragmented message", socket, connection)
          else
            connection = %{
              connection
              | fragment_pending: [connection.fragment_pending | frame.data],
                fragment_pending_count: connection.fragment_pending_count + 1,
                fragment_size: fragment_size
            }

            {:continue, maybe_coalesce_fragments(connection)}
          end
        end

      %Frame.Text{} ->
        do_error(1002, "Received unexpected text frame (RFC6455§5.4)", socket, connection)

      %Frame.Binary{} ->
        do_error(1002, "Received unexpected binary frame (RFC6455§5.4)", socket, connection)

      frame ->
        handle_control_frame(frame, socket, connection)
    end
  end

  defp maybe_coalesce_fragments(%{fragment_pending_count: count} = connection)
       when count >= @max_pending_fragments do
    chunk = IO.iodata_to_binary(connection.fragment_pending)
    data = [connection.fragment_frame.data, chunk]

    %{
      connection
      | fragment_frame: %{connection.fragment_frame | data: data},
        fragment_pending: [],
        fragment_pending_count: 0
    }
  end

  defp maybe_coalesce_fragments(connection), do: connection

  defp clear_fragments(connection) do
    %{
      connection
      | fragment_frame: nil,
        fragment_size: 0,
        fragment_pending: [],
        fragment_pending_count: 0
    }
  end

  defp oversize_message?(size, opts) do
    case Keyword.get(opts, :max_fragmented_message_size, 8_000_000) do
      0 -> false
      max_fragmented_message_size -> size > max_fragmented_message_size
    end
  end

  defp handle_control_frame(frame, socket, connection) do
    case frame do
      %Frame.ConnectionClose{} = frame ->
        # This is a bit of a subtle case, see RFC6455§7.4.1-2
        reply_code =
          case frame.code do
            code when code in 1000..1003 or code in 1007..1011 or code > 2999 -> 1000
            _code -> 1002
          end

        {:continue, connection} = do_stop(reply_code, :remote, socket, connection)
        {:close, %{connection | state: :closed, compress: nil}}

      %Frame.Ping{} = frame ->
        connection =
          Socket.send_frame(socket, {:pong, frame.data}, false)
          |> do_send_metrics(connection)

        if function_exported?(connection.websock, :handle_control, 2) do
          connection.websock.handle_control({frame.data, opcode: :ping}, connection.websock_state)
          |> handle_continuation(socket, connection)
        else
          {:continue, connection}
        end

      %Frame.Pong{} = frame ->
        if function_exported?(connection.websock, :handle_control, 2) do
          connection.websock.handle_control({frame.data, opcode: :pong}, connection.websock_state)
          |> handle_continuation(socket, connection)
        else
          {:continue, connection}
        end
    end
  end

  defp do_recv_metrics(frame, connection) do
    metrics =
      Bandit.WebSocket.Frame.recv_metrics(frame)
      |> Enum.reduce(connection.metrics, fn {key, value}, metrics ->
        Map.update(metrics, key, value, &(&1 + value))
      end)

    %{connection | metrics: metrics}
  end

  defp do_send_metrics(metrics, connection) do
    metrics =
      metrics
      |> Enum.reduce(connection.metrics, fn {key, value}, metrics ->
        Map.update(metrics, key, value, &(&1 + value))
      end)

    %{connection | metrics: metrics}
  end

  def handle_close(socket, connection), do: do_error(1006, :closed, socket, connection)

  # Some uncertainty if this should be 1000 or 1001 @ https://github.com/mtrudel/bandit/issues/89
  def handle_shutdown(socket, connection), do: do_stop(1000, :shutdown, socket, connection)

  def handle_error({:deserializing, :max_frame_size_exceeded = reason}, socket, connection),
    do: do_error(1009, reason, socket, connection)

  def handle_error({:deserializing, reason}, socket, connection),
    do: do_error(1002, reason, socket, connection)

  def handle_error(reason, socket, connection), do: do_error(1011, reason, socket, connection)

  def handle_timeout(socket, connection), do: do_error(1002, :timeout, socket, connection)

  def handle_info(msg, socket, %{state: :open} = connection) do
    connection.websock.handle_info(msg, connection.websock_state)
    |> handle_continuation(socket, connection)
  end

  # The WebSock is terminated, so it must not see any more messages (GHSA-2v5v-8f9v-xh85)
  def handle_info(_msg, _socket, connection), do: {:continue, connection}

  defp handle_continuation(continuation, socket, connection) do
    case continuation do
      {:ok, websock_state} ->
        {:continue, %{connection | websock_state: websock_state}}

      {:reply, _status, msg, websock_state} ->
        do_deflate(msg, socket, %{connection | websock_state: websock_state})

      {:push, msg, websock_state} ->
        do_deflate(msg, socket, %{connection | websock_state: websock_state})

      {:stop, :normal, websock_state} ->
        do_stop(1000, :normal, socket, %{connection | websock_state: websock_state})

      {:stop, :normal, code, websock_state} ->
        do_stop(code, :normal, socket, %{connection | websock_state: websock_state})

      {:stop, :normal, code, msg, websock_state} ->
        case do_deflate(msg, socket, %{connection | websock_state: websock_state}) do
          {:continue, connection} -> do_stop(code, :normal, socket, connection)
          other -> other
        end

      {:stop, {:shutdown, :disconnected}, websock_state} ->
        do_stop(1000, :normal, socket, %{connection | websock_state: websock_state})

      {:stop, {:shutdown, :restart}, websock_state} ->
        do_stop(1012, :normal, socket, %{connection | websock_state: websock_state})

      {:stop, reason, websock_state} ->
        do_error(1011, reason, socket, %{connection | websock_state: websock_state})

      {:stop, reason, code, websock_state} ->
        do_error(code, reason, socket, %{connection | websock_state: websock_state})

      {:stop, reason, code, msg, websock_state} ->
        case do_deflate(msg, socket, %{connection | websock_state: websock_state}) do
          {:continue, connection} -> do_error(code, reason, socket, connection)
          other -> other
        end
    end
  end

  defp do_stop(code, reason, socket, connection) do
    connection =
      if connection.state == :open do
        if function_exported?(connection.websock, :terminate, 2) do
          connection.websock.terminate(reason, connection.websock_state)
        end

        Socket.close(socket, code)
        if connection.compress, do: PerMessageDeflate.close(connection.compress)
        Bandit.Telemetry.stop_span(connection.span, connection.metrics)
        %{connection | close_timer_ref: start_close_timer(connection.close_timeout)}
      else
        connection
      end

    {:continue, %{clear_fragments(connection) | state: :closing, compress: nil}}
  end

  # A peer that does not send its Close frame could keep a closing connection open with a trickle
  # of frames (each frame resets the read timeout), or forever if the read timeout is :infinity.
  # This timer gives a fixed limit. Bandit.WebSocket.Handler handles its message. The message holds
  # a new reference, so that no other process can send a message that closes the connection
  defp start_close_timer(nil), do: nil

  defp start_close_timer(close_timeout) do
    ref = make_ref()
    Process.send_after(self(), {:bandit_websocket_close_timeout, ref}, close_timeout)
    ref
  end

  defp do_error(code, reason, socket, connection) do
    if connection.state == :open do
      if function_exported?(connection.websock, :terminate, 2) do
        connection.websock.terminate(maybe_wrap_reason(reason), connection.websock_state)
      end

      Socket.close(socket, code)
      if connection.compress, do: PerMessageDeflate.close(connection.compress)
      Bandit.Telemetry.stop_span(connection.span, connection.metrics, %{error: reason})
    end

    {:error, reason, %{connection | state: :closed, compress: nil}}
  end

  defp maybe_wrap_reason(:timeout), do: :timeout
  defp maybe_wrap_reason(reason), do: {:error, reason}

  defp do_deflate(msgs, socket, connection) when is_list(msgs) do
    Enum.reduce(msgs, {:continue, connection}, fn
      msg, {:continue, connection} -> do_deflate(msg, socket, connection)
      _msg, other -> other
    end)
  end

  defp do_deflate({opcode, data} = msg, socket, connection) when opcode in [:text, :binary] do
    case PerMessageDeflate.deflate(data, connection.compress) do
      {:ok, data, compress} ->
        connection =
          Socket.send_frame(socket, {opcode, data}, true)
          |> do_send_metrics(connection)

        {:continue, %{connection | compress: compress}}

      {:error, :no_compress} ->
        connection =
          Socket.send_frame(socket, msg, false)
          |> do_send_metrics(connection)

        {:continue, connection}

      {:error, reason} ->
        do_error(1007, "Deflation error: #{inspect(reason)}", socket, connection)
    end
  end

  defp do_deflate({opcode, _data} = msg, socket, connection) when opcode in [:ping, :pong] do
    connection =
      Socket.send_frame(socket, msg, false)
      |> do_send_metrics(connection)

    {:continue, connection}
  end

  defp do_inflate(frame, socket, connection) do
    case PerMessageDeflate.inflate(frame.data, connection.compress) do
      {:ok, data, compress} ->
        frame = %{frame | data: data, compressed: false}
        connection = %{connection | compress: compress}
        dispatch_frame(frame, socket, connection)

      {:error, :no_compress} ->
        do_error(1002, "Received unexpected compressed frame (RFC6455§5.2)", socket, connection)

      {:error, :too_much_inflation} ->
        do_error(1009, "Received compressed frame inflating too much", socket, connection)

      {:error, _reason} ->
        do_error(1007, "Inflation error", socket, connection)
    end
  end
end
