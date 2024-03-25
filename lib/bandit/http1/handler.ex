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

    {:ok, transport_info} = Bandit.TransportInfo.init(socket)
    transport = %Bandit.HTTP1.Socket{socket: socket, buffer: data, opts: state.opts}

    try do
      {:ok, method, request_target, headers, transport} =
        Bandit.HTTPTransport.read_headers(transport)

      adapter =
        Bandit.Adapter.init(
          self(),
          transport,
          method,
          headers,
          state.opts
        )

      with {:ok, :no_upgrade} <-
             maybe_upgrade_h2c(
               state,
               adapter,
               transport_info,
               adapter.method,
               request_target,
               headers
             ),
           {:ok, %Plug.Conn{adapter: {Bandit.Adapter, adapter}} = conn} <-
             Bandit.Pipeline.run(
               {Bandit.Adapter, adapter},
               transport_info,
               adapter.method,
               request_target,
               headers,
               state.plug
             ) do
        Bandit.Telemetry.stop_span(span, adapter.metrics, %{
          conn: conn,
          status: conn.status,
          method: adapter.method,
          request_target: request_target
        })

        maybe_keepalive(adapter, state)
      else
        {:error, reason} ->
          attempt_to_send_fallback(transport, 400)

          Bandit.Telemetry.stop_span(span, %{}, %{
            error: reason,
            status: 400,
            method: adapter.method,
            request_target: request_target
          })

          if Keyword.get(state.opts.http_1, :log_protocol_errors, true) do
            {:error, reason, state}
          else
            {:close, state}
          end

        {:ok, :websocket, %Plug.Conn{adapter: {Bandit.Adapter, adapter}} = conn, upgrade_opts} ->
          Bandit.Telemetry.stop_span(span, adapter.metrics, %{
            conn: conn,
            status: conn.status,
            method: adapter.method,
            request_target: request_target
          })

          state =
            state
            |> Map.put(:upgrade_opts, upgrade_opts)
            |> Map.put(
              :origin_telemetry_span_context,
              Bandit.Telemetry.telemetry_span_context(span)
            )

          {:switch, Bandit.WebSocket.Handler, state}

        {:ok, :h2c, adapter, remote_settings, initial_request} ->
          Bandit.Telemetry.stop_span(span, adapter.metrics)

          state =
            state
            |> Map.put(:remote_settings, remote_settings)
            |> Map.put(:initial_request, initial_request)

          {:switch, Bandit.HTTP2.Handler, state}
      end
    rescue
      error in Bandit.HTTP1.Error ->
        _ = attempt_to_send_fallback(transport, error.status)
        Bandit.Telemetry.stop_span(span, %{}, %{error: error.message, status: error.status})

        if Keyword.get(state.opts.http_1, :log_protocol_errors, true) do
          {:error, error.message, state}
        else
          {:close, state}
        end

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

  defp maybe_upgrade_h2c(state, adapter, transport_info, method, request_target, headers) do
    with {:http_2_enabled, true} <- {:http_2_enabled, state.http_2_enabled},
         {:upgrade, "h2c"} <- {:upgrade, Bandit.Headers.get_header(headers, "upgrade")},
         %Bandit.TransportInfo{secure?: false} <- transport_info,
         {:ok, connection_headers} <- Bandit.Headers.get_connection_header_keys(headers),
         {:ok, remote_settings} <- get_h2c_remote_settings(headers),
         {:ok, data, adapter} <- do_read_req_body(adapter),
         resp_headers = [{"connection", "Upgrade"}, {"upgrade", "h2c"}],
         {:ok, _sent_body, adapter} <-
           Bandit.Adapter.send_resp(adapter, 101, resp_headers, <<>>) do
      headers =
        Enum.reject(headers, fn {key, _value} ->
          key == "connection" || key in connection_headers
        end)

      initial_request = {method, request_target, headers, data}

      {:ok, :h2c, adapter, remote_settings, initial_request}
    else
      {:http_2_enabled, false} -> {:ok, :no_upgrade}
      {:upgrade, _} -> {:ok, :no_upgrade}
      %Bandit.TransportInfo{secure?: true} -> {:error, "h2c must use http (RFC7540§3.2)"}
      {:error, error} -> {:error, error}
    end
  end

  # This function is only used during h2c upgrades
  defp do_read_req_body(adapter, acc \\ <<>>)

  defp do_read_req_body(_adapter, acc) when byte_size(acc) >= 8_000_000,
    do: {:error, :body_too_large}

  defp do_read_req_body(adapter, acc) do
    case Bandit.Adapter.read_req_body(adapter, []) do
      {:ok, chunk, adapter} -> {:ok, acc <> chunk, adapter}
      {:more, chunk, adapter} -> do_read_req_body(adapter, acc <> chunk)
    end
  end

  defp get_h2c_remote_settings(headers) do
    with {:settings, [{"http2-settings", settings_payload}]} <-
           {:settings, Enum.filter(headers, fn {key, _value} -> key == "http2-settings" end)},
         {:ok, remote_settings} <- Base.url_decode64(settings_payload, padding: false),
         {:ok, %{settings: remote_settings}} <-
           Bandit.HTTP2.Frame.Settings.deserialize(0, 0, remote_settings) do
      {:ok, remote_settings}
    else
      {:settings, _} -> {:error, "Expected exactly 1 http2-settings header (RFC7540§3.2.1)"}
      _error -> {:error, "Invalid http2-settings value (RFC7540§3.2.1)"}
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
