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
          span: Bandit.Telemetry.t(),
          metrics: map()
        }

  def init(websock, websock_state, connection_opts, socket) do
    compress = Keyword.get(connection_opts, :compress)

    connection_telemetry_span_context =
      ThousandIsland.Socket.telemetry_span(socket).telemetry_span_context

    span =
      Bandit.Telemetry.start_span(:websocket, %{compress: compress}, %{
        connection_telemetry_span_context: connection_telemetry_span_context
      })

    instance = %__MODULE__{
      websock: websock,
      websock_state: websock_state,
      compress: compress,
      opts: connection_opts,
      span: span
    }

    websock.init(websock_state) |> handle_continutation(socket, instance)
  end

  def handle_frame(frame, socket, %{fragment_frame: nil} = connection) do
    connection = do_recv_metrics(frame, connection)

    case frame do
      %Frame.Continuation{} ->
        do_error(1002, "Received unexpected continuation frame (RFC6455§5.4)", socket, connection)

      %Frame.Text{fin: true, compressed: true} = frame ->
        do_inflate(frame, socket, connection)

      %Frame.Text{fin: true} = frame ->
        if !Keyword.get(connection.opts, :validate_text_frames, true) || String.valid?(frame.data) do
          connection.websock.handle_in({frame.data, opcode: :text}, connection.websock_state)
          |> handle_continutation(socket, connection)
        else
          do_error(1007, "Received non UTF-8 text frame (RFC6455§8.1)", socket, connection)
        end

      %Frame.Text{fin: false} = frame ->
        {:continue, %{connection | fragment_frame: frame}}

      %Frame.Binary{fin: true, compressed: true} = frame ->
        do_inflate(frame, socket, connection)

      %Frame.Binary{fin: true} = frame ->
        connection.websock.handle_in({frame.data, opcode: :binary}, connection.websock_state)
        |> handle_continutation(socket, connection)

      %Frame.Binary{fin: false} = frame ->
        {:continue, %{connection | fragment_frame: frame}}

      frame ->
        handle_control_frame(frame, socket, connection)
    end
  end

  def handle_frame(frame, socket, %{fragment_frame: fragment_frame} = connection)
      when not is_nil(fragment_frame) do
    connection = do_recv_metrics(frame, connection)

    case frame do
      %Frame.Continuation{fin: true} = frame ->
        data = IO.iodata_to_binary([connection.fragment_frame.data | frame.data])
        frame = %{connection.fragment_frame | fin: true, data: data}
        handle_frame(frame, socket, %{connection | fragment_frame: nil})

      %Frame.Continuation{fin: false} = frame ->
        data = [connection.fragment_frame.data | frame.data]
        frame = %{connection.fragment_frame | fin: true, data: data}
        {:continue, %{connection | fragment_frame: frame}}

      %Frame.Text{} ->
        do_error(1002, "Received unexpected text frame (RFC6455§5.4)", socket, connection)

      %Frame.Binary{} ->
        do_error(1002, "Received unexpected binary frame (RFC6455§5.4)", socket, connection)

      frame ->
        handle_control_frame(frame, socket, connection)
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

        _ = do_stop(reply_code, :remote, socket, connection)
        {:close, %{connection | state: :closed}}

      %Frame.Ping{} = frame ->
        connection =
          Socket.send_frame(socket, {:pong, frame.data}, false)
          |> do_send_metrics(connection)

        if function_exported?(connection.websock, :handle_control, 2) do
          connection.websock.handle_control({frame.data, opcode: :ping}, connection.websock_state)
          |> handle_continutation(socket, connection)
        else
          {:continue, connection}
        end

      %Frame.Pong{} = frame ->
        if function_exported?(connection.websock, :handle_control, 2) do
          connection.websock.handle_control({frame.data, opcode: :pong}, connection.websock_state)
          |> handle_continutation(socket, connection)
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

  def handle_info(msg, socket, connection) do
    connection.websock.handle_info(msg, connection.websock_state)
    |> handle_continutation(socket, connection)
  end

  defp handle_continutation(continutation, socket, connection) do
    case continutation do
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
    if connection.state == :open do
      if function_exported?(connection.websock, :terminate, 2) do
        connection.websock.terminate(reason, connection.websock_state)
      end

      if connection.compress, do: PerMessageDeflate.close(connection.compress)
      _ = Socket.close(socket, code)
      Bandit.Telemetry.stop_span(connection.span, connection.metrics)
    end

    {:continue, %{connection | state: :closing}}
  end

  defp do_error(code, reason, socket, connection) do
    if connection.state == :open do
      if function_exported?(connection.websock, :terminate, 2) do
        connection.websock.terminate(maybe_wrap_reason(reason), connection.websock_state)
      end

      if connection.compress, do: PerMessageDeflate.close(connection.compress)
      _ = Socket.close(socket, code)
      Bandit.Telemetry.stop_span(connection.span, connection.metrics, %{error: reason})
    end

    {:error, reason, %{connection | state: :closed}}
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

      {:error, _reason} ->
        do_error(1007, "Deflation error", socket, connection)
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
        handle_frame(frame, socket, connection)

      {:error, :no_compress} ->
        do_error(1002, "Received unexpected compressed frame (RFC6455§5.2)", socket, connection)

      {:error, _reason} ->
        do_error(1007, "Inflation error", socket, connection)
    end
  end
end
