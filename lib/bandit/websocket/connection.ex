defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, PerMessageDeflate, Socket}

  defstruct websock: nil, websock_state: nil, state: :open, compress: nil, fragment_frame: nil

  @typedoc "Conection state"
  @type state :: :open | :closing

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          websock: WebSock.impl(),
          websock_state: WebSock.state(),
          state: state(),
          compress: PerMessageDeflate.t() | nil,
          fragment_frame: Frame.Text.t() | Frame.Binary.t() | nil
        }

  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity

  def init(websock, websock_state, connection_opts, socket) do
    compress = Keyword.get(connection_opts, :compress)
    instance = %__MODULE__{websock: websock, websock_state: websock_state, compress: compress}
    websock.init(websock_state) |> handle_continutation(socket, instance)
  end

  def handle_frame(frame, socket, %{fragment_frame: nil} = connection) do
    case frame do
      %Frame.Continuation{} ->
        do_error(1002, "Received unexpected continuation frame (RFC6455§5.4)", socket, connection)

      %Frame.Text{fin: true, compressed: true} = frame ->
        do_inflate(frame, socket, connection)

      %Frame.Text{fin: true} = frame ->
        if String.valid?(frame.data) do
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
    case frame do
      %Frame.Continuation{fin: true} = frame ->
        data = connection.fragment_frame.data <> frame.data
        frame = %{connection.fragment_frame | fin: true, data: data}
        handle_frame(frame, socket, %{connection | fragment_frame: nil})

      %Frame.Continuation{fin: false} = frame ->
        data = connection.fragment_frame.data <> frame.data
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
        if connection.state == :open do
          connection.websock.terminate(:remote, connection.websock_state)
          Socket.close(socket, reply_code(frame.code))
        end

        {:close, %{connection | state: :closing}}

      %Frame.Ping{} = frame ->
        Socket.send_frame(socket, {:pong, frame.data}, false)

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

  # This is a bit of a subtle case, see RFC6455§7.4.1-2
  defp reply_code(code) when code in 0..999 or code in 1004..1006 or code in 1012..2999, do: 1002
  defp reply_code(_code), do: 1000

  def handle_close(socket, connection), do: do_error(1006, :closed, socket, connection)

  def handle_shutdown(socket, connection) do
    if connection.state == :open do
      connection.websock.terminate(:shutdown, connection.websock_state)
      Socket.close(socket, 1001)
    end
  end

  def handle_error({:protocol, reason}, socket, connection),
    do: do_error(1002, reason, socket, connection)

  def handle_error(reason, socket, connection), do: do_error(1011, reason, socket, connection)

  def handle_timeout(socket, connection) do
    if connection.state == :open do
      connection.websock.terminate(:timeout, connection.websock_state)
      Socket.close(socket, 1002)
    end
  end

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
        if connection.state == :open do
          connection.websock.terminate(:normal, connection.websock_state)
          Socket.close(socket, 1000)
        end

        {:continue, %{connection | websock_state: websock_state, state: :closing}}

      {:stop, reason, websock_state} ->
        do_error(1011, reason, socket, %{connection | websock_state: websock_state})
    end
  end

  defp do_error(code, reason, socket, connection) do
    if connection.state == :open do
      connection.websock.terminate({:error, reason}, connection.websock_state)
      Socket.close(socket, code)
    end

    {:error, reason, %{connection | state: :closing}}
  end

  defp do_deflate(msgs, socket, connection) when is_list(msgs) do
    Enum.reduce(msgs, {:continue, connection}, fn
      msg, {:continue, connection} -> do_deflate(msg, socket, connection)
      _msg, other -> other
    end)
  end

  defp do_deflate({opcode, data} = msg, socket, connection) when opcode in [:text, :binary] do
    case PerMessageDeflate.deflate(data, connection.compress) do
      {:ok, data, compress} ->
        Socket.send_frame(socket, {opcode, data}, true)
        {:continue, %{connection | compress: compress}}

      {:error, :no_compress} ->
        Socket.send_frame(socket, msg, false)
        {:continue, connection}

      {:error, _reason} ->
        do_error(1007, "Deflation error", socket, connection)
    end
  end

  defp do_deflate({opcode, _data} = msg, socket, connection) when opcode in [:ping, :pong] do
    Socket.send_frame(socket, msg, false)
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
