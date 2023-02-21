defprotocol Bandit.WebSocket.Socket do
  @moduledoc false
  #
  # A protocol defining the low-level functionality of a WebSocket
  #

  @type frame_type :: :text | :binary | :ping | :pong

  @spec send_frame(socket :: t(), {frame_type :: frame_type(), data :: iodata()}, boolean()) ::
          keyword()
  def send_frame(socket, data_and_frame_type, compressed)

  @spec close(socket :: t(), code :: WebSock.close_detail()) :: :ok
  def close(socket, code)
end

defimpl Bandit.WebSocket.Socket, for: ThousandIsland.Socket do
  @moduledoc false
  #
  # An implementation of Bandit.WebSocket.Socket for use with ThousandIsland.Socket instances
  #

  alias Bandit.WebSocket.Frame

  def send_frame(socket, {:text, data}, compressed) do
    do_send_frame(socket, %Frame.Text{fin: true, data: data, compressed: compressed})
    [send_text_frame_count: 1, send_text_frame_bytes: IO.iodata_length(data)]
  end

  def send_frame(socket, {:binary, data}, compressed) do
    do_send_frame(socket, %Frame.Binary{fin: true, data: data, compressed: compressed})
    [send_binary_frame_count: 1, send_binary_frame_bytes: IO.iodata_length(data)]
  end

  def send_frame(socket, {:ping, data}, false) do
    do_send_frame(socket, %Frame.Ping{data: data})
    [send_ping_frame_count: 1, send_ping_frame_bytes: IO.iodata_length(data)]
  end

  def send_frame(socket, {:pong, data}, false) do
    do_send_frame(socket, %Frame.Pong{data: data})
    [send_pong_frame_count: 1, send_pong_frame_bytes: IO.iodata_length(data)]
  end

  def close(socket, {code, detail}) when is_integer(code) do
    do_send_frame(socket, %Frame.ConnectionClose{code: code, reason: detail})
    ThousandIsland.Socket.shutdown(socket, :write)
  end

  def close(socket, code) when is_integer(code) do
    do_send_frame(socket, %Frame.ConnectionClose{code: code})
    ThousandIsland.Socket.shutdown(socket, :write)
  end

  defp do_send_frame(socket, frame) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
