defprotocol Bandit.WebSocket.Socket do
  @moduledoc false
  #
  # A protocol defining the low-level functionality of a WebSocket
  #

  @type frame_type :: :text | :binary | :ping | :pong

  @spec send_frame(socket :: t(), {frame_type :: frame_type(), data :: binary()}) :: :ok
  def send_frame(socket, data_and_frame_type)

  @spec close(socket :: t(), code :: Bandit.WebSocket.Frame.ConnectionClose.status_code()) :: :ok
  def close(socket, code)
end

defimpl Bandit.WebSocket.Socket, for: ThousandIsland.Socket do
  @moduledoc false
  #
  # An implementation of Bandit.WebSocket.Socket for use with ThousandIsland.Socket instances
  #

  alias Bandit.WebSocket.Frame

  def send_frame(socket, {:text, data}) do
    do_send_frame(socket, %Frame.Text{fin: true, data: data})
  end

  def send_frame(socket, {:binary, data}) do
    do_send_frame(socket, %Frame.Binary{fin: true, data: data})
  end

  def send_frame(socket, {:ping, data}) do
    do_send_frame(socket, %Frame.Ping{data: data})
  end

  def send_frame(socket, {:pong, data}) do
    do_send_frame(socket, %Frame.Pong{data: data})
  end

  def close(socket, code) do
    do_send_frame(socket, %Frame.ConnectionClose{code: code})
    ThousandIsland.Socket.shutdown(socket, :write)
  end

  defp do_send_frame(socket, frame) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
