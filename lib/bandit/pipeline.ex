defmodule Bandit.Pipeline do
  @moduledoc false
  # Provides a common pipeline for HTTP/1.1 and h2 adapters, factoring together shared
  # functionality relating to `Plug.Conn` management

  @type plug_def :: {module(), Plug.opts()}
  @type transport_info ::
          {secure? :: boolean(), ThousandIsland.Transport.socket_info(),
           ThousandIsland.Transport.socket_info(), ThousandIsland.Telemetry.t()}
  @type request_target ::
          {scheme(), nil | Plug.Conn.host(), nil | Plug.Conn.port_number(), path()}
  @type scheme :: String.t() | nil
  @type path :: String.t() | :*

  @spec run(
          Plug.Conn.adapter(),
          transport_info(),
          Plug.Conn.method(),
          request_target(),
          Plug.Conn.headers(),
          plug_def()
        ) :: {:ok, Plug.Conn.t()} | {:ok, :websocket, Plug.Conn.t(), tuple()} | {:error, term()}
  def run(req, transport_info, method, request_target, headers, plug) do
    with {:ok, conn} <- build_conn(req, transport_info, method, request_target, headers),
         conn <- call_plug(conn, plug),
         {:ok, :no_upgrade} <- maybe_upgrade(conn) do
      {:ok, commit_response(conn)}
    end
  end

  @spec build_conn(
          Plug.Conn.adapter(),
          transport_info(),
          Plug.Conn.method(),
          request_target(),
          Plug.Conn.headers()
        ) :: {:ok, Plug.Conn.t()} | {:error, String.t()}
  defp build_conn({mod, req}, transport_info, method, request_target, headers) do
    with {:ok, scheme} <- determine_scheme(transport_info, request_target),
         version <- mod.get_http_protocol(req),
         {:ok, host, port} <-
           determine_host_and_port(transport_info, version, request_target, headers),
         {path, query} <- determine_path_and_query(request_target) do
      uri = %URI{scheme: scheme, host: host, port: port, path: path, query: query}
      {_, _, {remote_ip, _port}, _} = transport_info
      {:ok, Plug.Conn.Adapter.conn({mod, req}, method, uri, remote_ip, headers)}
    end
  end

  @spec determine_scheme(transport_info(), request_target()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp determine_scheme({secure?, _, _, _}, {scheme, _, _, _}) do
    case {scheme, secure?} do
      {nil, true} -> {:ok, "https"}
      {nil, false} -> {:ok, "http"}
      {scheme, _} -> {:ok, scheme}
    end
  end

  @spec determine_host_and_port(
          transport_info(),
          version :: atom(),
          request_target(),
          Plug.Conn.headers()
        ) ::
          {:ok, Plug.Conn.host(), Plug.Conn.port_number()} | {:error, String.t()}
  defp determine_host_and_port({_, local_info, _, _}, version, {_, nil, nil, _}, headers) do
    with host_header when is_binary(host_header) <- Bandit.Headers.get_header(headers, "host"),
         {:ok, host, port} <- Bandit.Headers.parse_hostlike_header(host_header) do
      {:ok, host, port || determine_local_port(local_info)}
    else
      nil ->
        case version do
          :"HTTP/1.0" -> {:ok, "", determine_local_port(local_info)}
          _ -> {:error, "No host header"}
        end

      error ->
        error
    end
  end

  defp determine_host_and_port(
         {_, local_info, _, _},
         _version,
         {_, host, port, _},
         _headers
       ),
       do: {:ok, to_string(host), port || determine_local_port(local_info)}

  @spec determine_local_port(ThousandIsland.Transport.socket_info()) :: integer()
  defp determine_local_port({family, _}) when family in [:local, :unspec, :undefined], do: 0
  defp determine_local_port({_ip, port}), do: port

  @spec determine_path_and_query(request_target()) :: {String.t(), nil | String.t()}
  defp determine_path_and_query({_, _, _, :*}), do: {"*", nil}
  defp determine_path_and_query({_, _, _, path}), do: split_path(path)

  @spec split_path(String.t()) :: {String.t(), nil | String.t()}
  defp split_path(path) do
    path
    |> to_string()
    |> :binary.split("#")
    |> hd()
    |> :binary.split("?")
    |> case do
      [path, query] -> {path, query}
      [path] -> {path, nil}
    end
  end

  @spec call_plug(Plug.Conn.t(), plug_def()) :: Plug.Conn.t() | no_return()
  defp call_plug(%Plug.Conn{} = conn, {plug, plug_opts}) do
    case plug.call(conn, plug_opts) do
      %Plug.Conn{} = conn -> conn
      other -> raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(other)}")
    end
  end

  @spec maybe_upgrade(Plug.Conn.t()) ::
          {:ok, :no_upgrade} | {:ok, :websocket, Plug.Conn.t(), tuple()} | {:error, any()}
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
        _ = %{conn | state: :unset} |> Plug.Conn.send_resp(400, reason)
        {:error, reason}
    end
  end

  defp maybe_upgrade(_conn), do: {:ok, :no_upgrade}

  @spec commit_response(Plug.Conn.t()) :: Plug.Conn.t() | no_return()
  defp commit_response(conn) do
    case conn do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} ->
        Plug.Conn.send_resp(conn)

      %Plug.Conn{state: :chunked, adapter: {mod, req}} ->
        mod.chunk(req, "")
        conn

      %Plug.Conn{} ->
        conn
    end
  end
end
