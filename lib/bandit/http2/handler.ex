defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler. Responsible for:

  * Verifying the connection preface (RFC7540§3.5) upon initial connection
  * Coordinating the parsing of frames & attendant error handling
  * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    case Connection.init(socket) do
      {:ok, connection} ->
        {:ok, :continue, state |> Map.merge(%{buffer: <<>>, connection: connection})}

      {:error, reason} ->
        {:error, reason, state}
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
end
