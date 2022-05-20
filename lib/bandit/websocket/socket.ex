defprotocol Bandit.WebSocket.Socket do
  @moduledoc false
  #
  # A protocol describing the functionality of a WebSocket 'socket' Adapter
  #

  alias Bandit.WebSocket.Frame

  @spec send_frame(socket :: t, frame :: Frame.frame()) :: :ok
  def send_frame(socket, frame)
end

defimpl Bandit.WebSocket.Socket, for: ThousandIsland.Socket do
  @moduledoc false
  #
  # An implementation of Bandit.WebSocket.Socket for use with ThousandIsland.Socket instances
  #

  def send_frame(socket, frame) do
    ThousandIsland.Socket.send(socket, Bandit.WebSocket.Frame.serialize(frame))
  end
end
