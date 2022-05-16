defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  alias Bandit.HTTP1.Adapter

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{plug: plug} = state) do
    with req <- %Adapter{socket: socket, buffer: data},
         {:ok, conn} <- build_conn(req),
         {:ok, :no_upgrade} <- should_upgrade(conn),
         {:ok, conn} <- call_plug(conn, plug),
         {:ok, conn} <- commit_response(conn, plug) do
      case keepalive?(conn) do
        true -> {:continue, state}
        false -> {:close, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
      {:ok, :websocket, conn} -> {:switch, Bandit.WebSocket.Handler, Map.put(state, :conn, conn)}
    end
  end

  defp build_conn(req) do
    case Adapter.read_headers(req) do
      {:ok, headers, method, path, req} ->
        %{address: remote_ip} = Adapter.get_peer_data(req)

        # Parse a string to build a URI struct. This is quite a hack. In general, canonicalizing
        # URIs is a delicate process & rather than building a half-baked implementation here it's
        # better to leave a simple and ugly hack in place so that future improvements are obvious.
        # Future paths here are discussed at https://github.com/elixir-plug/plug/issues/948)
        {"host", host} = List.keyfind(headers, "host", 0, {"host", nil})
        scheme = if Adapter.secure?(req), do: :https, else: :http
        uri = URI.parse("#{scheme}://#{host}#{path}")
        {:ok, Plug.Conn.Adapter.conn({Adapter, req}, method, uri, remote_ip, headers)}

      {:error, :timeout} ->
        attempt_to_send_fallback(req, 408)
        {:error, "timeout reading request"}

      {:error, reason} ->
        attempt_to_send_fallback(req, 400)
        {:error, reason}
    end
  end

  defp should_upgrade(conn) do
    case Bandit.WebSocket.HTTP1Handshake.http1_handshake?(conn) do
      true -> {:ok, :websocket, conn}
      false -> {:ok, :no_upgrade}
    end
  end

  defp call_plug(%Plug.Conn{adapter: {Adapter, req}} = conn, {plug, plug_opts}) do
    {:ok, plug.call(conn, plug_opts)}
  rescue
    exception ->
      # Raise here so that users can see useful stacktraces
      attempt_to_send_fallback(req, 500)
      reraise(exception, __STACKTRACE__)
  end

  defp commit_response(conn, plug) do
    case conn do
      %Plug.Conn{state: :unset} ->
        {:error, "Plug did not send a response"}

      %Plug.Conn{state: :set} ->
        {:ok, Plug.Conn.send_resp(conn)}

      %Plug.Conn{state: :chunked, adapter: {Adapter, req}} ->
        Adapter.chunk(req, "")
        {:ok, conn}

      %Plug.Conn{} ->
        {:ok, conn}

      other ->
        {:error, "Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(other)}"}
    end
  end

  defp keepalive?(%Plug.Conn{adapter: {_, req}}), do: Adapter.keepalive?(req)

  defp attempt_to_send_fallback(req, code) do
    Adapter.send_resp(req, code, [], <<>>)
  rescue
    _ -> :ok
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
end
