defmodule Bandit.HTTP1.Handler do
  @moduledoc false
  # An HTTP 1.0 & 1.1 Thousand Island Handler

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    transport = %Bandit.HTTP1.Socket{socket: socket, buffer: data, opts: state.opts}
    connection_span = ThousandIsland.Socket.telemetry_span(socket)

    case Bandit.Pipeline.run(transport, state.plug, connection_span, state.opts) do
      {:ok, transport} -> maybe_keepalive(transport, state)
      {:error, _reason} -> {:close, state}
      {:upgrade, _transport, :websocket, opts} -> do_websocket_upgrade(opts, state)
    end
  end

  defp maybe_keepalive(transport, state) do
    requests_processed = Map.get(state, :requests_processed, 0) + 1
    request_limit = Keyword.get(state.opts.http_1, :max_requests, 0)
    under_limit = request_limit == 0 || requests_processed < request_limit

    if under_limit && transport.keepalive do
      if Keyword.get(state.opts.http_1, :clear_process_dict, true), do: clear_process_dict()
      gc_every_n_requests = Keyword.get(state.opts.http_1, :gc_every_n_keepalive_requests, 5)
      if rem(requests_processed, gc_every_n_requests) == 0, do: :erlang.garbage_collect()
      {:continue, Map.put(state, :requests_processed, requests_processed)}
    else
      {:close, state}
    end
  end

  defp clear_process_dict do
    Process.get_keys()
    |> Enum.each(&if &1 not in ~w[$ancestors $initial_call]a, do: Process.delete(&1))
  end

  defp do_websocket_upgrade(upgrade_opts, state) do
    :erlang.garbage_collect()
    {:switch, Bandit.WebSocket.Handler, Map.put(state, :upgrade_opts, upgrade_opts)}
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
