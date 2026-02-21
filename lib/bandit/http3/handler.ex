defmodule Bandit.HTTP3.Handler do
  @moduledoc false
  # GenServer managing one QUIC connection for HTTP/3.
  #
  # Started by `Bandit.HTTP3.Listener` via the `:quic_listener` connection
  # handler callback. One Handler is spawned per accepted QUIC connection and
  # owns the lifetime of all request `StreamProcess` children for that
  # connection.
  #
  # ## QUIC message protocol
  #
  # The Handler receives messages from the QUIC library in the form:
  #
  #   {:quic, conn_ref, {:connected, info}}
  #   {:quic, conn_ref, {:stream_opened, stream_id}}
  #   {:quic, conn_ref, {:stream_data, stream_id, data, fin}}
  #   {:quic, conn_ref, {:closed, reason}}
  #
  # ## Outbound sending
  #
  # Sending is delegated to an injected `quic_fns` map so that tests can run
  # without the real `:quic` library. The map contains:
  #
  #   %{
  #     send: fn(stream_id, data, fin) -> :ok end,
  #     open_unidirectional: fn() -> {:ok, stream_id} end
  #   }
  #
  # In production this is built from `conn_ref` in `start_link/4`. Tests
  # supply it via the `:quic_fns` key in `opts`.
  #
  # ## Stream process ownership
  #
  # The Handler traps exits so it is notified when StreamProcess children die
  # and can remove them from the connection's stream table.

  use GenServer

  require Logger

  # HTTP/3 unidirectional control stream type byte (RFC 9114 §6.2)
  @control_stream_type_byte 0x00

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(pid() | nil, reference() | term(), Bandit.Pipeline.plug_def(), map()) ::
          GenServer.on_start()
  def start_link(_conn_pid, conn_ref, plug, opts) do
    # opts is a map (e.g. %{http: [...], http_3: [...]}) in production.
    # Tests may supply a :quic_fns key to inject a test-friendly send function.
    quic_fns = Map.get(opts, :quic_fns) || build_quic_fns(conn_ref)
    GenServer.start_link(__MODULE__, {conn_ref, plug, opts, quic_fns})
  end

  # ---------------------------------------------------------------------------
  # GenServer init
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init({conn_ref, plug, opts, quic_fns}) do
    Process.flag(:trap_exit, true)

    state = %{
      conn_ref: conn_ref,
      plug: plug,
      opts: opts,
      quic_fns: quic_fns,
      connection: nil,
      peer_data: %{address: {0, 0, 0, 0}, port: 0, ssl_cert: nil},
      sock_data: %{address: {0, 0, 0, 0}, port: 0}
    }

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # QUIC connection established
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:quic, conn_ref, {:connected, info}}, %{conn_ref: conn_ref} = state) do
    require Logger
    Logger.debug("[H3 DEBUG] Handler received :connected, info=#{inspect(info)}")
    {peer_ip, peer_port} = extract_peer_address(info)

    peer_data = %{address: peer_ip, port: peer_port, ssl_cert: nil}
    sock_data = %{address: {0, 0, 0, 0}, port: 0}

    # HTTP/3 is always over TLS; conn_data marks the connection as secure.
    conn_data = {true, peer_ip}

    span =
      Bandit.Telemetry.start_span(:connection, %{}, %{
        plug: state.plug,
        remote_address: peer_ip,
        remote_port: peer_port
      })

    connection = Bandit.HTTP3.Connection.init(state.plug, state.opts, conn_data, span)

    # RFC 9114 §6.2.1: server MUST open a control stream and send SETTINGS
    # before any other HTTP/3 frames.
    Logger.debug("[H3 DEBUG] calling open_control_stream")
    result = open_control_stream(state.quic_fns, state.opts)
    Logger.debug("[H3 DEBUG] open_control_stream result=#{inspect(result)}")

    {:noreply,
     %{state | connection: connection, peer_data: peer_data, sock_data: sock_data}}
  end

  # ---------------------------------------------------------------------------
  # New QUIC stream opened by peer
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:quic, conn_ref, {:stream_opened, stream_id}}, %{conn_ref: conn_ref} = state) do
    if state.connection do
      connection =
        Bandit.HTTP3.Connection.handle_stream_opened(stream_id, self(), state.connection)

      {:noreply, %{state | connection: connection}}
    else
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Data received on a stream
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info(
        {:quic, conn_ref, {:stream_data, stream_id, data, fin}},
        %{conn_ref: conn_ref} = state
      ) do
    require Logger
    Logger.debug("[H3 DEBUG] Handler recv stream_data stream_id=#{stream_id} size=#{byte_size(data)} fin=#{fin} has_conn=#{state.connection != nil}")
    if state.connection do
      connection =
        Bandit.HTTP3.Connection.handle_stream_data(stream_id, data, fin, state.connection, self())

      {:noreply, %{state | connection: connection}}
    else
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # QUIC connection closed
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:quic, conn_ref, {:closed, reason}}, %{conn_ref: conn_ref} = state) do
    if state.connection && state.connection.telemetry_span do
      Bandit.Telemetry.stop_span(state.connection.telemetry_span, %{}, %{
        reason: reason
      })
    end

    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Stream process exited — remove from connection stream table
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:EXIT, pid, _reason}, state) do
    if state.connection do
      connection = Bandit.HTTP3.Connection.stream_terminated(pid, state.connection)
      {:noreply, %{state | connection: connection}}
    else
      {:noreply, state}
    end
  end

  # Ignore unrecognised messages (quic_listener may emit others)
  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Calls from stream processes — outbound data
  # ---------------------------------------------------------------------------

  # Stream process sends response headers
  @impl GenServer
  def handle_call({:send_headers, stream_id, headers, end_stream}, _from, state) do
    block = Bandit.HTTP3.QPACK.encode_headers(headers)
    frame = Bandit.HTTP3.Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
    state.quic_fns.send.(stream_id, frame, end_stream)
    {:reply, :ok, state}
  end

  # Stream process sends response body chunk
  @impl GenServer
  def handle_call({:send_data, stream_id, data, end_stream}, _from, state) do
    data = IO.iodata_to_binary(data)
    frame = Bandit.HTTP3.Frame.serialize({:data, data}) |> IO.iodata_to_binary()
    state.quic_fns.send.(stream_id, frame, end_stream)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Calls from stream processes — connection metadata
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_call({:peer_data, _stream_id}, _from, state) do
    {:reply, state.peer_data, state}
  end

  @impl GenServer
  def handle_call({:sock_data, _stream_id}, _from, state) do
    {:reply, state.sock_data, state}
  end

  @impl GenServer
  def handle_call({:ssl_data, _stream_id}, _from, state) do
    # QUIC TLS state is not exposed by this library currently; return empty map.
    {:reply, %{}, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Build production quic_fns. Use the :quic public API which handles conn_ref
  # being a reference (it does the ref→pid lookup internally).
  defp build_quic_fns(conn_ref) do
    %{
      send: fn stream_id, data, fin ->
        :quic.send_data(conn_ref, stream_id, data, fin)
      end,
      open_unidirectional: fn ->
        :quic.open_unidirectional_stream(conn_ref)
      end
    }
  end

  # Open a server control stream and send our SETTINGS frame on it.
  defp open_control_stream(quic_fns, opts) do
    settings = build_settings(opts)
    settings_frame = Bandit.HTTP3.Frame.serialize({:settings, settings}) |> IO.iodata_to_binary()
    # Prepend stream type byte (0x00 = control stream per RFC 9114 §6.2)
    payload = <<@control_stream_type_byte>> <> settings_frame

    case quic_fns.open_unidirectional.() do
      {:ok, stream_id} ->
        quic_fns.send.(stream_id, payload, false)

      {:error, reason} ->
        Logger.warning("HTTP/3: failed to open control stream: #{inspect(reason)}",
          domain: [:bandit]
        )
    end
  end

  defp build_settings(opts) do
    http3_opts = Map.get(opts, :http_3, [])
    max_field_section_size = Keyword.get(http3_opts, :max_field_section_size, 65_536)

    [
      # SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0 (static table only)
      {Bandit.HTTP3.Frame.settings_qpack_max_table_capacity(), 0},
      # SETTINGS_MAX_FIELD_SECTION_SIZE
      {Bandit.HTTP3.Frame.settings_max_field_section_size(), max_field_section_size}
    ]
  end

  defp extract_peer_address(%{peer_addr: {ip, port}}), do: {ip, port}
  defp extract_peer_address(%{address: ip, port: port}), do: {ip, port}
  defp extract_peer_address(_), do: {{0, 0, 0, 0}, 0}
end
