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

    req = %Bandit.HTTP1.Adapter{
      socket: socket,
      buffer: data,
      opts: state.opts,
      websocket_enabled: state.websocket_enabled
    }

    with {:ok, transport_info} <- Bandit.TransportInfo.init(socket),
         req <- %{req | transport_info: transport_info},
         {:ok, request_target, req} <- Bandit.HTTP1.Adapter.read_request_line(req) do
      try do
        with {:ok, headers, req} <- Bandit.HTTP1.Adapter.read_headers(req),
             {:ok, :no_upgrade} <-
               maybe_upgrade_h2c(state, req, transport_info, req.method, request_target, headers),
             {:ok, %Plug.Conn{adapter: {Bandit.HTTP1.Adapter, req}} = conn} <-
               Bandit.Pipeline.run(
                 {Bandit.HTTP1.Adapter, req},
                 transport_info,
                 req.method,
                 request_target,
                 headers,
                 state.plug
               ) do
          Bandit.Telemetry.stop_span(span, req.metrics, %{
            conn: conn,
            status: conn.status,
            method: req.method,
            request_target: request_target
          })

          maybe_keepalive(req, state)
        else
          {:error, reason} ->
            code = code_for_reason(reason)
            _ = attempt_to_send_fallback(req, code)

            Bandit.Telemetry.stop_span(span, %{}, %{
              error: reason,
              status: code,
              method: req.method,
              request_target: request_target
            })

            {:error, reason, state}

          {:ok, :websocket, %Plug.Conn{adapter: {Bandit.HTTP1.Adapter, req}} = conn, upgrade_opts} ->
            Bandit.Telemetry.stop_span(span, req.metrics, %{
              conn: conn,
              status: conn.status,
              method: req.method,
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

          {:ok, :h2c, req, remote_settings, initial_request} ->
            Bandit.Telemetry.stop_span(span, req.metrics)

            state =
              state
              |> Map.put(:remote_settings, remote_settings)
              |> Map.put(:initial_request, initial_request)

            {:switch, Bandit.HTTP2.Handler, state}
        end
      rescue
        exception ->
          # Raise here so that users can see useful stacktraces
          _ = attempt_to_send_fallback(req, 500)
          Bandit.Telemetry.span_exception(span, :exit, exception, __STACKTRACE__)
          reraise(exception, __STACKTRACE__)
      end
    else
      {:error, reason} ->
        code = code_for_reason(reason)
        _ = attempt_to_send_fallback(req, code)
        Bandit.Telemetry.stop_span(span, %{}, %{error: reason, code: code})
        {:error, reason, state}
    end
  end

  defp code_for_reason(:timeout), do: 408
  defp code_for_reason(:request_uri_too_long), do: 414
  defp code_for_reason(:header_too_long), do: 431
  defp code_for_reason(:too_many_headers), do: 431
  defp code_for_reason(_), do: 400

  defp attempt_to_send_fallback(req, code) do
    receive do
      @already_sent ->
        send(self(), @already_sent)
    after
      0 ->
        try do
          Bandit.HTTP1.Adapter.send_resp(req, code, [], <<>>)
        rescue
          _ -> :ok
        end
    end
  end

  defp maybe_keepalive(req, state) do
    requests_processed = Map.get(state, :requests_processed, 0) + 1
    request_limit = Keyword.get(state.opts.http_1, :max_requests, 0)
    under_limit = request_limit == 0 || requests_processed < request_limit

    if under_limit && req.keepalive do
      case ensure_body_read(req) do
        :ok -> {:continue, Map.put(state, :requests_processed, requests_processed)}
        {:error, :closed} -> {:close, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:close, state}
    end
  end

  defp ensure_body_read(%{read_state: :no_body}), do: :ok
  defp ensure_body_read(%{read_state: :body_read}), do: :ok

  defp ensure_body_read(req) do
    case Bandit.HTTP1.Adapter.read_req_body(req, []) do
      {:ok, _data, _req} -> :ok
      {:more, _data, req} -> ensure_body_read(req)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_upgrade_h2c(state, req, transport_info, method, request_target, headers) do
    with {:http_2_enabled, true} <- {:http_2_enabled, state.http_2_enabled},
         {:upgrade, "h2c"} <- {:upgrade, Bandit.Headers.get_header(headers, "upgrade")},
         %Bandit.TransportInfo{secure?: false} <- transport_info,
         {:ok, connection_headers} <- Bandit.Headers.get_connection_header_keys(headers),
         {:ok, remote_settings} <- get_h2c_remote_settings(headers),
         {:ok, data, req} <- do_read_req_body(req),
         resp_headers = [{"connection", "Upgrade"}, {"upgrade", "h2c"}],
         {:ok, _sent_body, req} <- Bandit.HTTP1.Adapter.send_resp(req, 101, resp_headers, <<>>) do
      headers =
        Enum.reject(headers, fn {key, _value} ->
          key == "connection" || key in connection_headers
        end)

      initial_request = {method, request_target, headers, data}

      {:ok, :h2c, req, remote_settings, initial_request}
    else
      {:http_2_enabled, false} -> {:ok, :no_upgrade}
      {:upgrade, _} -> {:ok, :no_upgrade}
      %Bandit.TransportInfo{secure?: true} -> {:error, "h2c must use http (RFC7540§3.2)"}
      {:error, error} -> {:error, error}
    end
  end

  # This function is only used during h2c upgrades
  defp do_read_req_body(req, acc \\ <<>>)

  defp do_read_req_body(_req, acc) when byte_size(acc) >= 8_000_000, do: {:error, :body_too_large}

  defp do_read_req_body(req, acc) do
    case Bandit.HTTP1.Adapter.read_req_body(req, []) do
      {:ok, chunk, req} -> {:ok, acc <> chunk, req}
      {:more, chunk, req} -> do_read_req_body(req, acc <> chunk)
      {:error, error} -> {:error, error}
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
