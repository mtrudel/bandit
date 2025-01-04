defmodule Bandit.InitialHandler do
  @moduledoc false
  # The initial protocol implementation used for all connections. Switches to a
  # specific protocol implementation based on configuration, ALPN negotiation, and
  # line heuristics.

  use ThousandIsland.Handler

  require Logger

  @type on_switch_handler ::
          {:switch, bandit_http_handler(), data :: term(), state :: term()}
          | {:switch, bandit_http_handler(), state :: term()}

  @type bandit_http_handler :: Bandit.HTTP1.Handler | Bandit.HTTP2.Handler

  # Attempts to guess the protocol in use, returning the applicable next handler and any
  # data consumed in the course of guessing which must be processed by the actual protocol handler
  @impl ThousandIsland.Handler
  @spec handle_connection(ThousandIsland.Socket.t(), state :: term()) ::
          ThousandIsland.Handler.handler_result() | on_switch_handler()
  def handle_connection(socket, state) do
    case {state.http_1_enabled, state.http_2_enabled, alpn_protocol(socket), sniff_wire(socket)} do
      {_, _, _, :likely_tls} ->
        Logger.warning("Connection that looks like TLS received on a clear channel",
          domain: [:bandit],
          plug: state.plug
        )

        {:close, state}

      {_, true, Bandit.HTTP2.Handler, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {true, _, Bandit.HTTP1.Handler, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      {_, true, :no_match, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {true, _, :no_match, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      _other ->
        {:close, state}
    end
  end

  # Returns the protocol as negotiated via ALPN, if applicable
  @spec alpn_protocol(ThousandIsland.Socket.t()) ::
          Bandit.HTTP2.Handler | Bandit.HTTP1.Handler | :no_match
  defp alpn_protocol(socket) do
    case ThousandIsland.Socket.negotiated_protocol(socket) do
      {:ok, "h2"} -> Bandit.HTTP2.Handler
      {:ok, "http/1.1"} -> Bandit.HTTP1.Handler
      _ -> :no_match
    end
  end

  # Returns the protocol as suggested by received data, if possible.
  # We do this in two phases so that we don't hang on *really* short HTTP/1
  # requests that are less than 24 bytes
  @spec sniff_wire(ThousandIsland.Socket.t()) ::
          Bandit.HTTP2.Handler
          | :likely_tls
          | {:no_match, binary()}
          | {:error, :closed | :timeout | :inet.posix()}
  defp sniff_wire(socket) do
    case ThousandIsland.Socket.recv(socket, 3) do
      {:ok, "PRI" = buffer} -> sniff_wire_for_http2(socket, buffer)
      {:ok, <<22::8, 3::8, minor::8>>} when minor in [1, 3] -> :likely_tls
      {:ok, data} -> {:no_match, data}
      {:error, :timeout} -> {:no_match, <<>>}
      {:error, error} -> {:error, error}
    end
  end

  defp sniff_wire_for_http2(socket, buffer) do
    case ThousandIsland.Socket.recv(socket, 21) do
      {:ok, " * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> Bandit.HTTP2.Handler
      {:ok, data} -> {:no_match, buffer <> data}
      {:error, :timeout} -> {:no_match, buffer}
      {:error, error} -> {:error, error}
    end
  end
end
