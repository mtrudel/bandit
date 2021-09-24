defmodule Bandit.InitialHandler do
  @moduledoc """
  The initial protocol implementation used for all connections. Switches to a 
  specific protocol implementation based on configuration, ALPN negotiation, and
  line heuristics.
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    guess_protocol(socket, state)
    |> case do
      {:ok, next_handler, data} -> setup_next_handler(next_handler, data, socket, state)
      {:error, error} -> {:error, error, state}
    end
  end

  defp guess_protocol(socket, state) do
    {alpn_protocol(socket), sniff_wire(socket, state.read_timeout)}
    |> case do
      {Bandit.HTTP2.Handler, Bandit.HTTP2.Handler} ->
        {:ok, Bandit.HTTP2.Handler, <<>>}

      {:no_match, Bandit.HTTP2.Handler} ->
        {:ok, Bandit.HTTP2.Handler, <<>>}

      {:no_match, {:no_match, data}} ->
        {:ok, Bandit.HTTP1.Handler, data}

      _other ->
        {:error, "Could not determine a protocol"}
    end
  end

  defp alpn_protocol(socket) do
    case ThousandIsland.Socket.negotiated_protocol(socket) do
      {:ok, "h2"} ->
        Bandit.HTTP2.Handler

      _ ->
        :no_match
    end
  end

  defp sniff_wire(socket, read_timeout) do
    case ThousandIsland.Socket.recv(socket, 24, read_timeout) do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> Bandit.HTTP2.Handler
      {:ok, data} -> {:no_match, data}
      {:error, error} -> {:error, error}
    end
  end

  defp setup_next_handler(next_handler, data, socket, state) do
    state = %{state | handler_module: next_handler}

    case Bandit.DelegatingHandler.handle_connection(socket, state) do
      {:ok, :continue, state} ->
        Bandit.DelegatingHandler.handle_data(data, socket, state)

      {:ok, :continue, state, _timeout} ->
        Bandit.DelegatingHandler.handle_data(data, socket, state)

      other ->
        other
    end
  end
end
