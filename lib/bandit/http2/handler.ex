defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler. Responsible for:

  * Verifying the connection preface (RFC7540§3.5) upon initial connection
  * Coordinating the parsing of frames & attendant error handling
  * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.Frame

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    with :ok <- read_preface(socket) do
      {:ok, :continue, state |> Map.merge(%{buffer: <<>>})}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, %{buffer: buffer} = state) do
    (buffer <> data)
    |> Stream.unfold(&Frame.deserialize/1)
    |> Enum.reduce_while({:ok, :continue, state}, fn
      {:ok, nil}, {:ok, :continue, state} ->
        {:cont, {:ok, :continue, state}}

      {:ok, _frame}, {:ok, :continue, state} ->
        # TODO - implement HTTP/2
        {:cont, {:ok, :continue, state}}

      {:more, rest}, {:ok, :continue, state} ->
        {:halt, {:ok, :continue, %{state | buffer: rest}}}

      {:error, _stream, _code, reason}, {:ok, :continue, state} ->
        # TODO - improve error handling here
        {:halt, {:error, reason, state}}
    end)
  end

  defp read_preface(socket) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> :ok
      _ -> {:error, "Did not receive expected HTTP/2 connection preface (RFC7540§3.5)"}
    end
  end
end
