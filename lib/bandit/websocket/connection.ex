defmodule Bandit.WebSocket.Connection do
  @moduledoc false
  # Implementation of a WebSocket lifecycle, implemented using a Socket protocol for communication

  alias Bandit.WebSocket.{Frame, Handshake, Socket}

  def handle_connection(_socket, conn) do
    # TODO - ask sock to negotiate_connection and determine subprotocols, path, etc
    Handshake.send_handshake(conn)
    # TODO - tell sock that we've nailed up the connection and they can send via socket
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
        IO.inspect(other)
    end

    # TODO - buffer continuation frames if needed
    # TODO - call with complete frame once its arrived
    # TODO - handle control frames without prejudice

    {:continue, connection}
  end
end
