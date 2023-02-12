defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_span_id: ThousandIsland.Socket.telemetry_span(socket).span_id
      })

    req = %Bandit.HTTP1.Adapter{socket: socket, buffer: data}

    try do
      with {:ok, headers, method, request_target, req} <- Bandit.HTTP1.Adapter.read_headers(req),
           transport_info <- build_transport_info(socket),
           {:ok, {Bandit.HTTP1.Adapter, req}} <-
             Bandit.Pipeline.run(
               {Bandit.HTTP1.Adapter, req},
               transport_info,
               method,
               request_target,
               headers,
               state.plug
             ) do
        Bandit.Telemetry.stop_span(span, req.metrics)
        if Bandit.HTTP1.Adapter.keepalive?(req), do: {:continue, state}, else: {:close, state}
      else
        {:error, :timeout} ->
          attempt_to_send_fallback(req, 408)
          Bandit.Telemetry.stop_span(span, %{}, %{error: "timeout"})
          {:error, "timeout reading request", state}

        {:error, reason} ->
          attempt_to_send_fallback(req, 400)
          Bandit.Telemetry.stop_span(span, %{}, %{error: reason})
          {:error, reason, state}

        {:ok, :websocket, {Bandit.HTTP1.Adapter, req}, upgrade_opts} ->
          Bandit.Telemetry.stop_span(span, req.metrics)
          {:switch, Bandit.WebSocket.Handler, Map.put(state, :upgrade_opts, upgrade_opts)}
      end
    rescue
      exception ->
        # Raise here so that users can see useful stacktraces
        attempt_to_send_fallback(req, 500)

        Bandit.Telemetry.span_event(span, :exception, %{}, %{
          kind: :exit,
          exception: exception,
          stacktrace: __STACKTRACE__
        })

        reraise(exception, __STACKTRACE__)
    end
  end

  defp build_transport_info(socket) do
    {ThousandIsland.Socket.secure?(socket), ThousandIsland.Socket.local_info(socket),
     ThousandIsland.Socket.peer_info(socket)}
  end

  defp attempt_to_send_fallback(req, code) do
    Bandit.HTTP1.Adapter.send_resp(req, code, [], <<>>)
  rescue
    _ -> :ok
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
end
