defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.Frame

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> {:ok, :continue, Map.put(state, :buffer, <<>>)}
      {:ok, _} -> {:error, "Did not receive expected HTTP/2 connection preface", state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, %{buffer: buffer} = state) do
    (buffer <> data)
    |> Frame.deserialize()
    |> case do
      {:ok, nil, rest} ->
        {:ok, :continue, %{state | buffer: rest}}

      {:ok, _frame, rest} ->
        # TODO - implement HTTP/2
        {:ok, :continue, %{state | buffer: rest}}

      {:more, rest} ->
        {:ok, :continue, %{state | buffer: rest}}

      {:error, _stream, _code, reason} ->
        # TODO - improve error handling here
        {:error, reason, state}
    end
  end
end
