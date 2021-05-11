defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> {:ok, :continue, state}
      {:ok, _} -> {:error, "Did not receive expected HTTP/2 connection preface", state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(_data, _socket, %{plug: _plug} = state) do
    # TODO - implement HTTP/2
    {:ok, :close, state}
  end
end
