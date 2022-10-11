defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Socket}

  defstruct sock: nil, sock_state: nil, state: :open, fragment_frame: nil

  @typedoc "Conection state"
  @type state :: :open | :closing

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          sock: Sock.impl(),
          sock_state: Sock.state(),
          state: state(),
          fragment_frame: Frame.Text.t() | Frame.Binary.t() | nil
        }

  def init(sock, sock_state) do
    {:ok, sock_state} = sock.init(sock_state)
    %__MODULE__{sock: sock, sock_state: sock_state}
  end

  def handle_frame(frame, socket, %{fragment_frame: nil} = connection) do
    case frame do
      %Frame.Continuation{} ->
        do_error(1002, "Received unexpected continuation frame (RFC6455§5.4)", socket, connection)

      %Frame.Text{fin: true} = frame ->
        if String.valid?(frame.data) do
          connection.sock.handle_in({:text, frame.data}, connection.sock_state)
          |> handle_continutation(socket, connection)
        else
          do_error(1007, "Received non UTF-8 text frame (RFC6455§8.1)", socket, connection)
        end

      %Frame.Text{fin: false} = frame ->
        {:continue, %{connection | fragment_frame: frame}}

      %Frame.Binary{fin: true} = frame ->
        connection.sock.handle_in({:binary, frame.data}, connection.sock_state)
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
          connection.sock.terminate(:remote, connection.sock_state)
          Socket.close(socket, reply_code(frame.code))
        end

        {:close, %{connection | state: :closing}}

      %Frame.Ping{} = frame ->
        Socket.send_frame(socket, {:pong, frame.data})

        if function_exported?(connection.sock, :handle_control, 2) do
          connection.sock.handle_control({:ping, frame.data}, connection.sock_state)
          |> handle_continutation(socket, connection)
        else
          {:continue, connection}
        end

      %Frame.Pong{} = frame ->
        if function_exported?(connection.sock, :handle_control, 2) do
          connection.sock.handle_control({:pong, frame.data}, connection.sock_state)
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
      connection.sock.terminate(:shutdown, connection.sock_state)
      Socket.close(socket, 1001)
    end
  end

  def handle_error(reason, socket, connection), do: do_error(1011, reason, socket, connection)

  def handle_timeout(socket, connection) do
    if connection.state == :open do
      connection.sock.terminate(:timeout, connection.sock_state)
      Socket.close(socket, 1002)
    end
  end

  def handle_info(msg, socket, connection) do
    connection.sock.handle_info(msg, connection.sock_state)
    |> handle_continutation(socket, connection)
  end

  defp handle_continutation(continutation, socket, connection) do
    case continutation do
      {:ok, sock_state} ->
        {:continue, %{connection | sock_state: sock_state}}

      {:push, msg, sock_state} ->
        Socket.send_frame(socket, msg)
        {:continue, %{connection | sock_state: sock_state}}

      {:stop, :normal, sock_state} ->
        if connection.state == :open do
          connection.sock.terminate(:normal, connection.sock_state)
          Socket.close(socket, 1000)
        end

        {:continue, %{connection | sock_state: sock_state, state: :closing}}

      {:stop, reason, sock_state} ->
        do_error(1011, reason, socket, %{connection | sock_state: sock_state})
    end
  end

  defp do_error(code, reason, socket, connection) do
    if connection.state == :open do
      connection.sock.terminate({:error, reason}, connection.sock_state)
      Socket.close(socket, code)
    end

    {:error, reason, %{connection | state: :closing}}
  end
end
