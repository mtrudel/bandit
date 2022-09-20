defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Handshake}

  defstruct sock: nil, sock_state: nil, state: :open, fragment_frame: nil

  @typedoc "Conection state"
  @type state :: :open | :closing

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          sock: module(),
          sock_state: Sock.state(),
          state: state(),
          fragment_frame: Frame.Text.t() | Frame.Binary.t() | nil
        }

  def init({sock, sock_state}) do
    %__MODULE__{sock: sock, sock_state: sock_state}
  end

  def handle_connection(conn, socket, connection) do
    case connection.sock.negotiate(conn, connection.sock_state) do
      {:accept, conn, sock_state} ->
        Handshake.send_handshake(conn)

        connection.sock.handle_connection(socket, sock_state)
        |> handle_continutation(socket, connection)

      {:refuse, conn, _sock_state} ->
        if conn.state != :sent, do: Plug.Conn.send_resp(conn)
        {:close, connection}
    end
  end

  def handle_frame(frame, socket, %{fragment_frame: nil} = connection) do
    case frame do
      %Frame.Continuation{} ->
        do_error(1002, "Received unexpected continuation frame (RFC6455§5.4)", socket, connection)

      %Frame.Text{fin: true} = frame ->
        if String.valid?(frame.data) do
          connection.sock.handle_text_frame(frame.data, socket, connection.sock_state)
          |> handle_continutation(socket, connection)
        else
          do_error(1007, "Received non UTF-8 text frame (RFC6455§8.1)", socket, connection)
        end

      %Frame.Text{fin: false} = frame ->
        {:continue, %{connection | fragment_frame: frame}}

      %Frame.Binary{fin: true} = frame ->
        connection.sock.handle_binary_frame(frame.data, socket, connection.sock_state)
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
        do_connection_close(frame.code || 1005, socket, connection)
        {:close, connection}

      %Frame.Ping{} = frame ->
        Sock.Socket.send_pong_frame(socket, frame.data)

        connection.sock.handle_ping_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      %Frame.Pong{} = frame ->
        connection.sock.handle_pong_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)
    end
  end

  def handle_close(socket, connection), do: do_connection_close(1006, socket, connection)
  def handle_shutdown(socket, connection), do: do_connection_close(1001, socket, connection)

  def handle_error(reason, socket, connection) do
    do_error(1011, reason, socket, connection)
  end

  def handle_timeout(socket, connection) do
    if connection.state == :open do
      connection.sock.handle_timeout(socket, connection.sock_state)
      Bandit.WebSocket.Socket.close(socket, 1002)
    end
  end

  defp handle_continutation(continutation, socket, connection) do
    case continutation do
      {:continue, sock_state} ->
        {:continue, %{connection | sock_state: sock_state}}

      {:close, sock_state} ->
        do_connection_close(1000, socket, %{connection | sock_state: sock_state})
        {:continue, %{connection | sock_state: sock_state, state: :closing}}

      {:error, reason, sock_state} ->
        do_error(1011, reason, socket, %{connection | sock_state: sock_state})
    end
  end

  defp do_connection_close(status_code, socket, connection) do
    if connection.state == :open do
      connection.sock.handle_close(status_code, socket, connection.sock_state)
      Bandit.WebSocket.Socket.close(socket, status_code)
    end
  end

  defp do_error(code, reason, socket, connection) do
    if connection.state == :open do
      connection.sock.handle_error(reason, socket, connection.sock_state)
      Bandit.WebSocket.Socket.close(socket, code)
    end

    {:error, reason, %{connection | state: :closing}}
  end
end
