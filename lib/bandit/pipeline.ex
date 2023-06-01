defmodule Bandit.Pipeline do
  @moduledoc false
  # Provides a common pipeline for HTTP/1.1 and h2 adapters, factoring together shared
  # functionality relating to `Plug.Conn` management

  @type plug_def :: {module(), Plug.opts()}
  @type transport_info ::
          {boolean(), ThousandIsland.Transport.socket_info(),
           ThousandIsland.Transport.socket_info(), ThousandIsland.Telemetry.t()}
  @type request_target :: {scheme(), host(), Plug.Conn.port_number(), path()}
  @type scheme :: String.t() | nil
  @type host :: Plug.Conn.host() | nil
  @type path :: String.t() | :*

  @spec run(
          Plug.Conn.adapter(),
          transport_info(),
          Plug.Conn.method(),
          request_target(),
          Plug.Conn.headers(),
          plug_def()
        ) :: {:ok, Plug.Conn.t()} | {:ok, :websocket, tuple()} | {:error, term()}
  def run(req, transport_info, method, request_target, headers, plug) do
    with {:ok, conn} <- build_conn(req, transport_info, method, request_target, headers),
         {:ok, conn} <- call_plug(conn, plug),
         {:ok, :no_upgrade} <- maybe_upgrade(conn) do
      commit_response(conn, plug)
    end
  end

  defp build_conn({mod, req}, transport_info, method, request_target, headers) do
    with {:ok, scheme} <- determine_scheme(transport_info, request_target),
         version <- mod.get_http_protocol(req),
         {:ok, host, port} <-
           determine_host_and_port(transport_info, version, request_target, headers),
         {:ok, path, query} <- determine_path_and_query(request_target) do
      uri = %URI{scheme: scheme, host: host, port: port, path: path, query: query}
      {_, _, %{address: remote_ip}, _} = transport_info
      {:ok, Plug.Conn.Adapter.conn({mod, req}, method, uri, remote_ip, headers)}
    end
  end

  defp determine_scheme({secure?, _, _, _}, {scheme, _, _, _}) do
    case {scheme, secure?} do
      {nil, true} -> {:ok, "https"}
      {"https", true} -> {:ok, "https"}
      {nil, false} -> {:ok, "http"}
      {"http", false} -> {:ok, "http"}
      _ -> {:error, "request target scheme does not agree with transport"}
    end
  end

  defp determine_host_and_port({_, local_info, _, _}, version, {_, nil, nil, _}, headers) do
    with host_header when not is_nil(host_header) <- Bandit.Headers.get_header(headers, "host"),
         {:ok, host, port} <- Bandit.Headers.parse_hostlike_header(host_header) do
      {:ok, host, port || local_info[:port]}
    else
      nil ->
        case version do
          :"HTTP/1.0" -> {:ok, "", local_info[:port]}
          _ -> {:error, "No host header"}
        end

      error ->
        error
    end
  end

  defp determine_host_and_port({_, local_info, _, _}, _version, {_, host, port, _}, _headers),
    do: {:ok, to_string(host), port || local_info[:port]}

  defp determine_path_and_query({_, _, _, :*}), do: {:ok, "*", nil}
  defp determine_path_and_query({_, _, _, path}), do: split_path(path)

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

  defp call_plug(%Plug.Conn{} = conn, {plug, plug_opts}), do: {:ok, plug.call(conn, plug_opts)}

  defp maybe_upgrade(
         %Plug.Conn{
           state: :upgraded,
           adapter:
             {_,
              %{upgrade: {:websocket, {websock, websock_opts, connection_opts}, websocket_opts}}}
         } = conn
       ) do
    # We can safely unset the state, since we match on :upgraded above
    case Bandit.WebSocket.Handshake.handshake(
           %{conn | state: :unset},
           connection_opts,
           websocket_opts
         ) do
      {:ok, conn, connection_opts} ->
        {:ok, :websocket, conn, {websock, websock_opts, connection_opts}}

      {:error, reason} ->
        %{conn | state: :unset} |> Plug.Conn.send_resp(400, reason)
        _ = %{conn | state: :unset} |> Plug.Conn.send_resp(400, reason)
        {:error, reason}
    end
  end

  defp maybe_upgrade(_conn), do: {:ok, :no_upgrade}

  defp commit_response(conn, {plug, _plug_opts}), do: commit_response(conn, plug)

  defp commit_response(conn, plug) do
    case conn do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} ->
        {:ok, Plug.Conn.send_resp(conn)}

      %Plug.Conn{state: :chunked, adapter: {mod, req}} ->
        mod.chunk(req, "")
        {:ok, conn}

      %Plug.Conn{} ->
        {:ok, conn}

      other ->
        raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(other)}")
    end
  end
end
