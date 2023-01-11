defmodule Bandit.InitialHandler do
  @moduledoc false
  # The initial protocol implementation used for all connections. Switches to a
  # specific protocol implementation based on configuration, ALPN negotiation, and
  # line heuristics.

  use ThousandIsland.Handler

  require Logger

  # Attempts to guess the protocol in use, returning the applicable next handler and any
  # data consumed in the course of guessing which must be processed by the actual protocol handler
  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {alpn_protocol(socket), sniff_wire(socket)}
    |> case do
      {_, :likely_tls} ->
        Logger.warning("Connection that looks like TLS received on a clear channel")
        {:close, state}

      {Bandit.HTTP2.Handler, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {Bandit.HTTP1.Handler, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      {:no_match, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {:no_match, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      _other ->
        Logger.warning("Could not determine a protocol")
        {:close, state}
    end
  end

  # Returns the protocol as negotiated via ALPN, if applicable
  defp alpn_protocol(socket) do
    case ThousandIsland.Socket.negotiated_protocol(socket) do
      {:ok, "h2"} ->
        Bandit.HTTP2.Handler

      {:ok, "http/1.1"} ->
        Bandit.HTTP1.Handler

      _ ->
        :no_match
    end
  end

  # Returns the protocol as suggested by received data, if possible
  defp sniff_wire(socket) do
    case ThousandIsland.Socket.recv(socket, 24) do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> Bandit.HTTP2.Handler
      {:ok, <<22::8, 3::8, minor::8, _::binary>>} when minor in [1, 3] -> :likely_tls
      {:ok, data} -> {:no_match, data}
      {:error, error} -> {:error, error}
    end
  end
end
