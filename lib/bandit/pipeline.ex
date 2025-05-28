defmodule Bandit.Pipeline do
  @moduledoc false
  # Provides a common pipeline for HTTP/1.1 and h2 adapters, factoring together shared
  # functionality relating to `Plug.Conn` management

  @type plug_def :: {function() | module(), Plug.opts()}
  @type conn_data :: {boolean(), :inet.ip_address()}
  @type request_target ::
          {scheme(), nil | Plug.Conn.host(), nil | Plug.Conn.port_number(), path()}
  @type scheme :: String.t() | nil
  @type path :: String.t() | :*

  require Logger

  @spec run(
          Bandit.HTTPTransport.t(),
          plug_def(),
          ThousandIsland.Telemetry.t() | Bandit.Telemetry.t(),
          conn_data(),
          map()
        ) ::
          {:ok, Bandit.HTTPTransport.t()}
          | {:upgrade, Bandit.HTTPTransport.t(), :websocket, tuple()}
          | {:error, term()}
  def run(transport, plug, connection_span, conn_data, opts) do
    measurements = %{monotonic_time: Bandit.Telemetry.monotonic_time()}

    metadata = %{
      connection_telemetry_span_context: connection_span.telemetry_span_context,
      plug: plug
    }

    try do
      {:ok, method, request_target, headers, transport} =
        Bandit.HTTPTransport.read_headers(transport)

      conn = build_conn!(transport, method, request_target, headers, conn_data, opts)
      span = Bandit.Telemetry.start_span(:request, measurements, Map.put(metadata, :conn, conn))

      try do
        conn
        |> call_plug!(plug)
        |> maybe_upgrade!()
        |> case do
          {:no_upgrade, conn} ->
            %Plug.Conn{adapter: {_mod, adapter}} = conn = commit_response!(conn)
            Bandit.Telemetry.stop_span(span, adapter.metrics, %{conn: conn})
            {:ok, adapter.transport}

          {:upgrade, %Plug.Conn{adapter: {_mod, adapter}} = conn, protocol, opts} ->
            conn = Plug.Conn.put_status(conn, 101)
            Bandit.Telemetry.stop_span(span, adapter.metrics, %{conn: conn})
            {:upgrade, adapter.transport, protocol, opts}
        end
      catch
        kind, value ->
          handle_error(kind, value, __STACKTRACE__, transport, span, opts, plug: plug, conn: conn)
      end
    rescue
      exception ->
        span = Bandit.Telemetry.start_span(:request, measurements, metadata)
        handle_error(:error, exception, __STACKTRACE__, transport, span, opts, plug: plug)
    end
  end

  @spec build_conn!(
          Bandit.HTTPTransport.t(),
          Plug.Conn.method(),
          request_target(),
          Plug.Conn.headers(),
          conn_data(),
          map()
        ) :: Plug.Conn.t()
  defp build_conn!(transport, method, request_target, headers, {secure?, peer_address}, opts) do
    adapter = Bandit.Adapter.init(self(), transport, method, headers, opts)
    scheme = determine_scheme(secure?, request_target)
    version = Bandit.HTTPTransport.version(transport)
    {host, port} = determine_host_and_port!(scheme, version, request_target, headers)
    {path, query} = determine_path_and_query(request_target)
    uri = %URI{scheme: scheme, host: host, port: port, path: path, query: query}
    Plug.Conn.Adapter.conn({Bandit.Adapter, adapter}, method, uri, peer_address, headers)
  end

  @spec determine_scheme(boolean(), request_target()) :: String.t() | nil
  defp determine_scheme(secure?, {scheme, _, _, _}) do
    case {secure?, scheme} do
      {true, nil} -> "https"
      {false, nil} -> "http"
      {_, scheme} -> scheme
    end
  end

  @spec determine_host_and_port!(binary(), atom(), request_target(), Plug.Conn.headers()) ::
          {Plug.Conn.host(), Plug.Conn.port_number()}
  defp determine_host_and_port!(scheme, version, {_, nil, nil, _}, headers) do
    case {Bandit.Headers.get_header(headers, "host"), version} do
      {nil, :"HTTP/1.0"} ->
        {"", URI.default_port(scheme)}

      {nil, _} ->
        request_error!("Unable to obtain host and port: No host header")

      {host_header, _} ->
        {host, port} = Bandit.Headers.parse_hostlike_header!(host_header)
        {host, port || URI.default_port(scheme)}
    end
  end

  defp determine_host_and_port!(scheme, _version, {_, host, port, _}, _headers),
    do: {to_string(host), port || URI.default_port(scheme)}

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

  @spec call_plug!(Plug.Conn.t(), plug_def()) :: Plug.Conn.t() | no_return()
  defp call_plug!(%Plug.Conn{} = conn, {plug, plug_opts}) when is_atom(plug) do
    case plug.call(conn, plug_opts) do
      %Plug.Conn{} = conn -> conn
      other -> raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(other)}")
    end
  end

  defp call_plug!(%Plug.Conn{} = conn, {plug_fn, plug_opts}) when is_function(plug_fn) do
    case plug_fn.(conn, plug_opts) do
      %Plug.Conn{} = conn -> conn
      other -> raise("Expected Plug function to return %Plug.Conn{} but got: #{inspect(other)}")
    end
  end

  @spec maybe_upgrade!(Plug.Conn.t()) ::
          {:no_upgrade, Plug.Conn.t()} | {:upgrade, Plug.Conn.t(), :websocket, tuple()}
  defp maybe_upgrade!(
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
        {:upgrade, conn, :websocket, {websock, websock_opts, connection_opts}}

      {:error, reason} ->
        request_error!(reason)
    end
  end

  defp maybe_upgrade!(conn), do: {:no_upgrade, conn}

  @spec commit_response!(Plug.Conn.t()) :: Plug.Conn.t() | no_return()
  defp commit_response!(conn) do
    case conn do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} ->
        Plug.Conn.send_resp(conn)

      %Plug.Conn{state: :chunked, adapter: {mod, adapter}} ->
        adapter =
          case mod.chunk(adapter, "") do
            {:ok, _, adapter} -> adapter
            _ -> adapter
          end

        %{conn | adapter: {mod, adapter}}

      %Plug.Conn{} ->
        conn
    end
    |> then(fn %Plug.Conn{adapter: {mod, adapter}} = conn ->
      transport = Bandit.HTTPTransport.ensure_completed(adapter.transport)
      %{conn | adapter: {mod, %{adapter | transport: transport}}}
    end)
  end

  @spec request_error!(term()) :: no_return()
  @spec request_error!(term(), Plug.Conn.status()) :: no_return()
  defp request_error!(reason, plug_status \\ :bad_request) do
    raise Bandit.HTTPError, message: reason, plug_status: plug_status
  end

  @spec handle_error(
          :error | :throw | :exit,
          Exception.t() | term(),
          Exception.stacktrace(),
          Bandit.HTTPTransport.t(),
          Bandit.Telemetry.t(),
          map(),
          keyword()
        ) :: {:ok, Bandit.HTTPTransport.t()} | {:error, term()}
  defp handle_error(:error, %Plug.Conn.WrapperError{} = error, _, transport, span, opts, metadata) do
    # Unwrap the inner error and handle it
    handle_error(error.kind, error.reason, error.stack, transport, span, opts, metadata)
  end

  defp handle_error(:error, %type{} = error, stacktrace, transport, span, opts, metadata)
       when type in [
              Bandit.HTTPError,
              Bandit.TransportError,
              Bandit.HTTP2.Errors.StreamError,
              Bandit.HTTP2.Errors.ConnectionError
            ] do
    Bandit.Telemetry.stop_span(span, %{}, Enum.into(metadata, %{error: error.message}))

    Bandit.Logger.maybe_log_protocol_error(error, stacktrace, opts, metadata)

    # We want to do this at the end of the function, since the HTTP2 stack may kill this process
    # in the course of handling a ConnectionError
    Bandit.HTTPTransport.send_on_error(transport, error)
    {:error, error}
  end

  defp handle_error(kind, reason, stacktrace, transport, span, opts, metadata) do
    reason = Exception.normalize(kind, reason, stacktrace)

    Bandit.Telemetry.span_exception(span, kind, reason, stacktrace)
    status = reason |> Plug.Exception.status() |> Plug.Conn.Status.code()

    if status in Keyword.get(opts.http, :log_exceptions_with_status_codes, 500..599) do
      logger_metadata = Bandit.Logger.logger_metadata_for(kind, reason, stacktrace, metadata)
      Logger.error(Exception.format(kind, reason, stacktrace), logger_metadata)
    end

    Bandit.HTTPTransport.send_on_error(transport, reason)
    {:error, reason}
  end
end
