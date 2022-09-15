defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Handshake}

  defstruct sock: nil, sock_state: nil, state: :open, buffer: nil

  @typedoc "Conection state"
  @type state :: :open | :closing

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          sock: module(),
          sock_state: Sock.opts(),
          state: state(),
          buffer: Frame.frame()
        }

  @valid_close_codes [1000, 1001, 1002, 1003] ++
                       Enum.to_list(1005..1015) ++ Enum.to_list(3000..4999)

  def init({sock, sock_state}) do
    %__MODULE__{sock: sock, sock_state: sock_state}
  end

  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
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

  def handle_frame(frame, socket, %{buffer: nil} = connection) do
    case frame do
      %Frame.Text{fin: true, data: data} ->
        if String.valid?(data) do
          data
          |> connection.sock.handle_text_frame(socket, connection.sock_state)
          |> handle_continutation(socket, connection)
        else
          do_connection_close(1007, socket, connection)
          {:close, connection}
        end

      %Frame.Text{fin: false} = frame ->
        {:continue, %{connection | buffer: frame}}

      %Frame.Binary{fin: true, data: data} ->
        data
        |> connection.sock.handle_binary_frame(socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      %Frame.Binary{fin: false} = frame ->
        {:continue, %{connection | buffer: frame}}

      %Frame.ConnectionClose{code: code}
      when not is_nil(code) and code not in @valid_close_codes ->
        do_connection_close(1002, socket, connection)
        {:close, connection}

      %Frame.ConnectionClose{} = frame ->
        if frame.reason != <<>> and not String.valid?(frame.reason) do
          do_connection_close(1002, socket, connection)
          {:close, connection}
        else
          do_connection_close(frame.code || 1000, socket, connection)
          {:close, connection}
        end

      %Frame.Ping{} = frame ->
        Sock.Socket.send_pong_frame(socket, frame.data)

        connection.sock.handle_ping_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      %Frame.Pong{} = frame ->
        connection.sock.handle_pong_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      _ ->
        do_connection_close(1002, socket, connection)
        {:close, connection}
    end
  end

  def handle_frame(frame, socket, %{buffer: buffer} = connection) do
    case frame do
      %Frame.Continuation{fin: true} = frame ->
        buffer
        |> append_frame(frame)
        |> Map.put(:fin, true)
        |> handle_frame(socket, %{connection | buffer: nil})

      %Frame.Continuation{fin: false} = frame ->
        {:continue, %{connection | buffer: append_frame(buffer, frame)}}

      %Frame.ConnectionClose{} = frame ->
        if (frame.reason != <<>> and not String.valid?(frame.reason)) or
             (frame.code != nil and frame.code not in @valid_close_codes) do
          do_connection_close(1002, socket, connection)
          {:close, connection}
        else
          do_connection_close(frame.code || 1000, socket, connection)
          {:close, connection}
        end

      %Frame.Ping{} = frame ->
        Sock.Socket.send_pong_frame(socket, frame.data)

        connection.sock.handle_ping_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      %Frame.Pong{} = frame ->
        connection.sock.handle_pong_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      _ ->
        do_connection_close(1002, socket, connection)
        {:close, connection}
    end
  end

  def handle_close(socket, connection), do: do_connection_close(1006, socket, connection)
  def handle_shutdown(socket, connection), do: do_connection_close(1001, socket, connection)

  def handle_error(reason, socket, connection) do
    do_error(reason, socket, connection)
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
        do_error(reason, socket, %{connection | sock_state: sock_state})
        {:error, reason, %{connection | sock_state: sock_state, state: :closing}}
    end
  end

  defp do_connection_close(status_code, socket, connection) do
    if connection.state == :open do
      connection.sock.handle_close(status_code, socket, connection.sock_state)
      Bandit.WebSocket.Socket.close(socket, status_code)
    end
  end

  defp do_error(reason, socket, connection) do
    if connection.state == :open do
      connection.sock.handle_error(reason, socket, connection.sock_state)
      Bandit.WebSocket.Socket.close(socket, 1011)
    end
  end

  defp append_frame(frame1, frame2) do
    %{frame1 | data: frame1.data <> frame2.data}
  end
end
