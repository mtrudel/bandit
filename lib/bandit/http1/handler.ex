defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  @already_sent {:plug_conn, :sent}

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    connection_span = ThousandIsland.Socket.telemetry_span(socket)

    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_telemetry_span_context: connection_span.telemetry_span_context
      })

    transport = %Bandit.HTTP1.Socket{socket: socket, buffer: data, opts: state.opts}

    try do
      case Bandit.Pipeline.run(transport, state.plug, state.opts) do
        {:ok, %Plug.Conn{adapter: {_mod, adapter}} = conn} ->
          Bandit.Telemetry.stop_span(span, adapter.metrics, %{conn: conn})
          maybe_keepalive(adapter, state)

        {:error, reason} ->
          attempt_to_send_fallback(transport, 400)
          Bandit.Telemetry.stop_span(span, %{}, %{error: reason, status: 400})

          if Keyword.get(state.opts.http_1, :log_protocol_errors, true),
            do: {:error, reason, state},
            else: {:close, state}

        {:ok, :websocket, %Plug.Conn{adapter: {Bandit.Adapter, adapter}} = conn, upgrade_opts} ->
          Bandit.Telemetry.stop_span(span, adapter.metrics, %{conn: conn})

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
      error in Bandit.HTTP1.Error ->
        _ = attempt_to_send_fallback(transport, error.status)
        Bandit.Telemetry.stop_span(span, %{}, %{error: error.message, status: error.status})

        if Keyword.get(state.opts.http_1, :log_protocol_errors, true),
          do: {:error, error.message, state},
          else: {:close, state}

      error ->
        _ = attempt_to_send_fallback(transport, 500)
        Bandit.Telemetry.span_exception(span, :exit, error, __STACKTRACE__)
        reraise error, __STACKTRACE__
    end
  end

  defp attempt_to_send_fallback(transport, status) do
    receive do
      @already_sent ->
        send(self(), @already_sent)
    after
      0 ->
        try do
          Bandit.HTTP1.Socket.send_error(transport, status)
        rescue
          _ -> :ok
        end
    end
  end

  defp maybe_keepalive(adapter, state) do
    requests_processed = Map.get(state, :requests_processed, 0) + 1
    request_limit = Keyword.get(state.opts.http_1, :max_requests, 0)
    under_limit = request_limit == 0 || requests_processed < request_limit

    if under_limit && adapter.transport.keepalive do
      try do
        _ = Bandit.HTTPTransport.ensure_completed(adapter.transport)

        gc_every_n_requests = Keyword.get(state.opts.http_1, :gc_every_n_keepalive_requests, 5)
        if rem(requests_processed, gc_every_n_requests) == 0, do: :erlang.garbage_collect()

        {:continue, Map.put(state, :requests_processed, requests_processed)}
      rescue
        _error in Bandit.HTTP1.Error -> {:close, state}
      end
    else
      {:close, state}
    end
  end

  def handle_info({:plug_conn, :sent}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  def handle_info({:EXIT, _pid, :normal}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  def handle_info(msg, {socket, state}) do
    if Keyword.get(state.opts.http_1, :log_unknown_messages, false), do: log_no_handle_info(msg)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info(msg, state) do
    log_no_handle_info(msg)
    {:noreply, state}
  end

  defp log_no_handle_info(msg) do
    # Copied verbatim from lib/elixir/lib/gen_server.ex
    proc =
      case Process.info(self(), :registered_name) do
        {_, []} -> self()
        {_, name} -> name
      end

    :logger.error(
      %{
        label: {GenServer, :no_handle_info},
        report: %{
          module: __MODULE__,
          message: msg,
          name: proc
        }
      },
      %{
        domain: [:otp, :elixir],
        error_logger: %{tag: :error_msg},
        report_cb: &GenServer.format_report/1
      }
    )
  end
end
