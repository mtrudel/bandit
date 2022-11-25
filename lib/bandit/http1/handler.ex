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
         {:ok, conn} <- call_plug(conn, plug),
         {:ok, :no_upgrade} <- maybe_upgrade(conn),
         {:ok, conn} <- commit_response(conn, plug) do
      case keepalive?(conn) do
        true -> {:continue, state}
        false -> {:close, state}
      end
    else
      {:error, reason} ->
        {:error, reason, state}

      {:ok, :websocket, upgrade_opts} ->
        {:switch, Bandit.WebSocket.Handler, Map.put(state, :upgrade_opts, upgrade_opts)}
    end
  end

  defp build_conn(req) do
    with {:ok, headers, method, request_target, req} <- Adapter.read_headers(req),
         {:ok, scheme} <- determine_scheme(request_target, req),
         {:ok, host, port} <- determine_host_and_port(request_target, headers, req),
         {:ok, path, query} <- determine_path_and_query(request_target) do
      uri = %URI{scheme: scheme, host: host, port: port, path: path, query: query}
      %{address: remote_ip} = Adapter.get_peer_data(req)
      {:ok, Plug.Conn.Adapter.conn({Adapter, req}, method, uri, remote_ip, headers)}
    else
      {:error, :timeout} ->
        attempt_to_send_fallback(req, 408)
        {:error, "timeout reading request"}

      {:error, reason} ->
        attempt_to_send_fallback(req, 400)
        {:error, reason}
    end
  end

  defp determine_scheme({:absoluteURI, scheme, _, _, _}, req) do
    case {Adapter.secure?(req), scheme} do
      {true, :https} -> {:ok, "https"}
      {false, :http} -> {:ok, "http"}
      _ -> {:error, "request target scheme does not agree with transport"}
    end
  end

  defp determine_scheme(_request_target, req) do
    if Adapter.secure?(req), do: {:ok, "https"}, else: {:ok, "http"}
  end

  defp determine_host_and_port({:absoluteURI, _, host, port, _}, _headers, req) do
    case port do
      :undefined -> {:ok, to_string(host), Adapter.get_local_data(req)[:port]}
      port -> {:ok, to_string(host), port}
    end
  end

  defp determine_host_and_port(_request_target, headers, req) do
    with host_header when is_binary(host_header) <- Adapter.get_header(headers, "host"),
         {:ok, host, port} <- parse_host_header(host_header) do
      case port do
        :undefined -> {:ok, host, Adapter.get_local_data(req)[:port]}
        port -> {:ok, host, port}
      end
    else
      nil ->
        case req.version do
          :"HTTP/1.0" -> {:ok, "", Adapter.get_local_data(req)[:port]}
          _ -> {:error, "No host header"}
        end

      error ->
        error
    end
  end

  defp parse_host_header(host_header) do
    host_header
    |> :binary.split(":")
    |> case do
      [host, port] ->
        case Integer.parse(port) do
          {port, ""} when port > 0 -> {:ok, host, port}
          _ -> {:error, "Host header contains invalid port"}
        end

      [host] ->
        {:ok, host, :undefined}
    end
  end

  defp determine_path_and_query({:abs_path, path}), do: split_path(path)
  defp determine_path_and_query({:absoluteURI, _, _, _, path}), do: split_path(path)
  defp determine_path_and_query(:*), do: {:ok, "*", nil}

  defp split_path(path) do
    path
    |> to_string()
    |> :binary.split("#")
    |> hd()
    |> :binary.split("?")
    |> case do
      [path, query] -> {:ok, path, query}
      [path] -> {:ok, path, nil}
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

  defp maybe_upgrade(
         %Plug.Conn{
           state: :upgraded,
           adapter:
             {Adapter, %Adapter{upgrade: {:websocket, {websock, websock_opts, connection_opts}}}}
         } = conn
       ) do
    # We can safely unset the state, since we match on :upgraded above
    case Bandit.WebSocket.Handshake.handshake(%{conn | state: :unset}, connection_opts) do
      {:ok, connection_opts} ->
        {:ok, :websocket, {websock, websock_opts, connection_opts}}

      {:error, reason} ->
        %{conn | state: :unset} |> Plug.Conn.send_resp(400, reason)
        {:error, reason}
    end
  end

  defp maybe_upgrade(_conn), do: {:ok, :no_upgrade}

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
