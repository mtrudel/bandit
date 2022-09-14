defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Handshake}

  defstruct sock: nil, sock_state: nil, state: :open, buffer: []

  @typedoc "Conection state"
  @type state :: :open | :closing

  @typedoc "Encapsulates the state of a WebSocket connection"
  @type t :: %__MODULE__{
          sock: module(),
          sock_state: Sock.opts(),
          state: state(),
          buffer: [Frame.frame()]
        }

  @valid_close_codes [1000, 1001, 1002, 1003] ++
                       Enum.to_list(1005..1015) ++ Enum.to_list(3000..4999)

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

  def handle_frame(frame, socket, %{buffer: []} = connection) do
    case frame do
      %Frame.Text{fin: true} = frame ->
        if String.valid?(frame.data) do
          connection.sock.handle_text_frame(frame.data, socket, connection.sock_state)
          |> handle_continutation(socket, connection)
        else
          do_connection_close(1007, socket, connection)
          {:close, connection}
        end

      %Frame.Text{fin: false} = frame ->
        {:continue, %{connection | buffer: [frame | connection.buffer]}}

      %Frame.Binary{fin: true} = frame ->
        connection.sock.handle_binary_frame(frame.data, socket, connection.sock_state)
        |> handle_continutation(socket, connection)

      %Frame.Binary{fin: false} = frame ->
        {:continue, %{connection | buffer: [frame | connection.buffer]}}

      %Frame.ConnectionClose{code: code} when not is_nil(code) and code not in @valid_close_codes ->
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

  def handle_frame(frame, socket, connection) do
    case frame do
      %Frame.Continuation{fin: true} = frame ->
        if connection.buffer == [] do
          Bandit.WebSocket.Socket.close(socket, 1002)
        else
          [frame | connection.buffer]
          |> Enum.reverse()
          |> Enum.reduce(fn cont, frame ->
            %{frame | data: frame.data <> cont.data}
          end)
          |> Map.put(:fin, true)
          |> handle_frame(socket, %{connection | buffer: []})
        end

      %Frame.Continuation{fin: false} = frame ->
        if connection.buffer == [] do
          Bandit.WebSocket.Socket.close(socket, 1002)
        else
          {:continue, %{connection | buffer: [frame | connection.buffer]}}
        end

      %Frame.ConnectionClose{} = frame ->
        if (frame.reason != <<>> and not String.valid?(frame.reason)) or
             (frame.code != nil and frame.code not in @valid_close_codes) do
          IO.inspect(frame.code, label: "Code")
          IO.inspect("END")
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
end
