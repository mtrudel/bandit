defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    {_, _, _, connection_span} = transport_info = build_transport_info(socket)

    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_telemetry_span_context: connection_span.telemetry_span_context
      })

    req = %Bandit.HTTP1.Adapter{
      socket: socket,
      buffer: data,
      opts: state.opts,
      websocket_enabled: state.websocket_enabled
    }

    try do
      with {:ok, headers, method, request_target, req} <-
             Bandit.HTTP1.Adapter.read_headers(req),
           {:ok, %Plug.Conn{adapter: {Bandit.HTTP1.Adapter, req}} = conn} <-
             Bandit.Pipeline.run(
               {Bandit.HTTP1.Adapter, req},
               transport_info,
               method,
               request_target,
               headers,
               state.plug
             ) do
        Bandit.Telemetry.stop_span(span, Map.put(req.metrics, :conn, conn))
        maybe_keepalive(req, state)
      else
        {:error, reason} ->
          _ = attempt_to_send_fallback(req, code_for_reason(reason))
          Bandit.Telemetry.stop_span(span, %{}, %{error: reason})
          {:error, reason, state}

        {:ok, :websocket, %Plug.Conn{adapter: {Bandit.HTTP1.Adapter, req}} = conn, upgrade_opts} ->
          Bandit.Telemetry.stop_span(span, Map.put(req.metrics, :conn, conn))

          state =
            state
            |> Map.put(:upgrade_opts, upgrade_opts)
            |> Map.put(
              :origin_telemetry_span_context,
              Bandit.Telemetry.telemetry_span_context(span)
            )

          {:switch, Bandit.WebSocket.Handler, state}
      end
    rescue
      exception ->
        # Raise here so that users can see useful stacktraces
        _ = attempt_to_send_fallback(req, 500)
        Bandit.Telemetry.span_exception(span, :exit, exception, __STACKTRACE__)
        reraise(exception, __STACKTRACE__)
    end
  end

  defp build_transport_info(socket) do
    {ThousandIsland.Socket.secure?(socket), ThousandIsland.Socket.local_info(socket),
     ThousandIsland.Socket.peer_info(socket), ThousandIsland.Socket.telemetry_span(socket)}
  end

  defp code_for_reason(:timeout), do: 408
  defp code_for_reason(:request_uri_too_long), do: 414
  defp code_for_reason(:header_too_long), do: 431
  defp code_for_reason(:too_many_headers), do: 431
  defp code_for_reason(_), do: 400

  defp attempt_to_send_fallback(req, code) do
    Bandit.HTTP1.Adapter.send_resp(req, code, [], <<>>)
  rescue
    _ -> :ok
  end

  defp maybe_keepalive(req, state) do
    requests_processed = Map.get(state, :requests_processed, 0) + 1
    request_limit = Keyword.get(state.opts.http_1, :max_requests, 0)
    under_limit = request_limit == 0 || requests_processed < request_limit

    if under_limit && req.keepalive do
      {:continue, Map.put(state, :requests_processed, requests_processed)}
    else
      {:close, state}
    end
  end

  def handle_info({:plug_conn, :sent}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  def handle_info({:EXIT, _pid, :normal}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}
end
