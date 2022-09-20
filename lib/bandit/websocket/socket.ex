defprotocol Bandit.WebSocket.Socket do
  @moduledoc false
  #
  # A protocol adding close behaviour to the Sock.Socket protocol
  #

  @spec close(socket :: t(), code :: Bandit.WebSocket.Frame.ConnectionClose.status_code()) :: :ok
  def close(socket, code)
end

defimpl Sock.Socket, for: ThousandIsland.Socket do
  @moduledoc false
  #
  # An implementation of Sock.Socket for use with ThousandIsland.Socket instances
  #

  alias Bandit.WebSocket.Frame

  def send_text_frame(socket, data) do
    send_frame(socket, %Frame.Text{fin: true, data: data})
  end

  def send_binary_frame(socket, data) do
    send_frame(socket, %Frame.Binary{fin: true, data: data})
  end

  def send_ping_frame(socket, data) do
    send_frame(socket, %Frame.Ping{data: data})
  end

  def send_pong_frame(socket, data) do
    send_frame(socket, %Frame.Pong{data: data})
  end

  defp send_frame(socket, frame) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end

defimpl Bandit.WebSocket.Socket, for: ThousandIsland.Socket do
  @moduledoc false
  #
  # An implementation of Bandit.WebSocket.Socket for use with ThousandIsland.Socket instances
  #

  alias Bandit.WebSocket.Frame

  def close(socket, code) do
    send_frame(socket, %Frame.ConnectionClose{code: code})
    ThousandIsland.Socket.shutdown(socket, :write)
  end

  defp send_frame(socket, frame) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
