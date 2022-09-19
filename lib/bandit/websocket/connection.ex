defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Handshake, Socket}

  def handle_connection(_socket, conn) do
    Handshake.send_handshake(conn)
    {:continue, %{}}
  end

  def handle_data(data, socket, connection) do
    case Frame.deserialize(data) do
      {{:ok, %Frame.Text{} = frame}, <<>>} ->
        Socket.send_frame(socket, %Frame.Text{fin: true, data: String.upcase(frame.data)})

      {{:ok, %Frame.Binary{} = frame}, <<>>} ->
        Socket.send_frame(socket, %Frame.Binary{fin: true, data: frame.data})

      {{:ok, %Frame.Ping{} = frame}, <<>>} ->
        Socket.send_frame(socket, %Frame.Pong{data: frame.data})

      other ->
        :ok
    end

    {:continue, connection}
  end
end
