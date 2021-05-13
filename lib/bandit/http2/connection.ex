defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  defstruct local_settings: %{}, remote_settings: %{}

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

  defp send_frame(frame, socket) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end
