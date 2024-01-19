defmodule Bandit.HTTP2.StreamProcess do
  @moduledoc false
  # This process is where an actual Plug is executed, within the context of an HTTP/2 stream. There
  # is a bit of split responsibility between this module and the `Bandit.HTTP2.Adapter` module
  # which merits explanation:
  #
  # Broadly, this module is responsible for the execution of a Plug and does so within a GenServer
  # handle_continue call. The entirety of a Plug lifecycle takes place in this single call.
  #
  # The 'connection-facing' API for sending data to a stream process is expressed on this module
  # (via the `recv_*` functions) even though the 'other half' of those calls exists in the
  # `Bandit.HTTP2.Adapter` module. As a result, this module and the Handler module are fairly
  # tightly coupled, but together they express clear APIs towards both Plug applications and the
  # rest of Bandit.

  use GenServer, restart: :temporary

  alias Bandit.HTTP2.{Errors, StreamTransport}

  # A stream process can be created only once we have an adapter & set of headers. Pass them in
  # at creation time to ensure this invariant
  @spec start_link(StreamTransport.t(), Bandit.Telemetry.t()) :: GenServer.on_start()
  def start_link(stream_transport, connection_span) do
    GenServer.start_link(__MODULE__, {stream_transport, connection_span})
  end

  # Let the stream process know that header data has arrived from the client. This is implemented
  # further down in this file as a handle_info callback
  @spec recv_headers(pid(), Plug.Conn.headers(), Bandit.Pipeline.plug_def(), keyword()) ::
          :ok | :noconnect | :nosuspend
  def recv_headers(pid, headers, plug, opts), do: send(pid, {:headers, headers, plug, opts})

  # Let the stream process know that body data has arrived from the client. The other half of this
  # flow can be found in `Bandit.HTTP2.Adapter.read_req_body/2`
  @spec recv_data(pid(), iodata()) :: :ok | :noconnect | :nosuspend
  def recv_data(pid, data), do: send(pid, {:data, data})

  # Let the stream process know that the stream's send window has changed. The other half of this
  # flow can be found in `Bandit.HTTP2.Adapter.send_resp/4` and friends
  @spec recv_send_window_update(pid(), non_neg_integer()) :: :ok | :noconnect | :nosuspend
  def recv_send_window_update(pid, delta), do: send(pid, {:send_window_update, delta})

  # Let the stream process know that the client has set the end of stream flag. The other half of
  # this flow can be found in `Bandit.HTTP2.Adapter.read_req_body/2`
  @spec recv_end_of_stream(pid()) :: :ok | :noconnect | :nosuspend
  def recv_end_of_stream(pid), do: send(pid, :end_stream)

  # Let the stream process know that the client has reset the stream. This will terminate the
  # stream's handling process
  @spec recv_rst_stream(pid(), Errors.error_code()) :: true
  def recv_rst_stream(pid, error_code), do: Process.exit(pid, {:recv_rst_stream, error_code})

  @impl GenServer
  def init({stream_transport, connection_span}) do
    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_telemetry_span_context: connection_span.telemetry_span_context,
        stream_id: stream_transport.stream_id
      })

    {:ok, %{stream_transport: stream_transport, span: span}, {:continue, :start_stream}}
  end

  @impl GenServer
  def handle_continue(:start_stream, state) do
    stream_transport = StreamTransport.start_stream(state.stream_transport)
    {:noreply, %{state | stream_transport: stream_transport}}
  end

  @dialyzer {:nowarn_function, handle_info: 2}
  @impl GenServer
  def handle_info({:headers, headers, plug, opts}, state) do
    {:ok, method, request_target, headers, stream_transport} =
      StreamTransport.recv_headers(state.stream_transport, headers)

    adapter =
      {Bandit.HTTP2.Adapter,
       Bandit.HTTP2.Adapter.init(stream_transport, method, headers, self(), opts)}

    transport_info = state.stream_transport.transport_info

    case Bandit.Pipeline.run(adapter, transport_info, method, request_target, headers, plug) do
      {:ok, %Plug.Conn{adapter: {Bandit.HTTP2.Adapter, req}} = conn} ->
        Bandit.Telemetry.stop_span(state.span, req.metrics, %{
          conn: conn,
          method: method,
          request_target: request_target,
          status: conn.status
        })

        {:stop, :normal, %{state | stream_transport: req.stream_transport}}

      {:error, reason} ->
        raise Errors.StreamError, message: reason, error_code: Errors.internal_error()
    end
  end

  @impl GenServer
  def terminate(:normal, _state), do: :ok

  def terminate({%Errors.StreamError{} = error, _stacktrace}, state) do
    Bandit.Telemetry.stop_span(state.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target
    })

    StreamTransport.send_rst_stream(state.stream_transport, error.error_code)
  end

  def terminate({%Errors.ConnectionError{} = error, _stacktrace}, state) do
    Bandit.Telemetry.stop_span(state.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target
    })

    StreamTransport.send_shutdown_connection(
      state.stream_transport,
      error.error_code,
      error.message
    )
  end

  def terminate({exception, stacktrace}, state) when is_exception(exception) do
    Bandit.Telemetry.span_exception(state.span, :exit, exception, stacktrace)
    StreamTransport.send_rst_stream(state.stream_transport, Errors.internal_error())
  end
end
