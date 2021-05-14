defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  defstruct local_settings: %{}, remote_settings: %{}, last_stream_id: 0

  alias Bandit.HTTP2.Frame

  def init(socket) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} ->
        connection = %__MODULE__{}
        # Send SETTINGS frame per RFC7540§3.5
        %Frame.Settings{ack: false, settings: connection.local_settings}
        |> send_frame(socket)

        {:ok, connection}

      _ ->
        {:error, "Did not receive expected HTTP/2 connection preface (RFC7540§3.5)"}
    end
  end

  def handle_frame(%Frame.Settings{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Settings{ack: false, settings: settings}, socket, connection) do
    %Frame.Settings{ack: true} |> send_frame(socket)
    {:ok, :continue, %{connection | remote_settings: settings}}
  end

  def handle_frame(%Frame.Ping{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Ping{ack: false, payload: payload}, socket, connection) do
    %Frame.Ping{ack: true, payload: payload} |> send_frame(socket)
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Goaway{}, socket, %{last_stream_id: last_stream_id} = connection) do
    %Frame.Goaway{last_stream_id: last_stream_id} |> send_frame(socket)
    {:ok, :close, connection}
  end

  def handle_error(0, error_code, _reason, socket, %{last_stream_id: last_stream_id} = connection) do
    %Frame.Goaway{last_stream_id: last_stream_id, error_code: error_code} |> send_frame(socket)
    {:ok, :close, connection}
  end

  defp send_frame(frame, socket) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
