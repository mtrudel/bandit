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
  @spec start_link(
          StreamTransport.t(),
          Bandit.Pipeline.plug_def(),
          keyword(),
          Bandit.Telemetry.t()
        ) :: GenServer.on_start()
  def start_link(stream_transport, plug, opts, connection_span) do
    GenServer.start_link(__MODULE__, {stream_transport, plug, opts, connection_span})
  end

  @impl GenServer
  def init({stream_transport, plug, opts, connection_span}) do
    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_telemetry_span_context: connection_span.telemetry_span_context,
        stream_id: stream_transport.stream_id
      })

    {:ok, %{stream_transport: stream_transport, plug: plug, opts: opts, span: span},
     {:continue, :start_stream}}
  end

  @impl GenServer
  def handle_continue(:start_stream, state) do
    {:ok, method, request_target, headers, stream_transport} =
      StreamTransport.recv_headers(state.stream_transport)

    adapter =
      {Bandit.HTTP2.Adapter,
       Bandit.HTTP2.Adapter.init(stream_transport, method, headers, self(), state.opts)}

    transport_info = state.stream_transport.transport_info

    case Bandit.Pipeline.run(adapter, transport_info, method, request_target, headers, state.plug) do
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

    StreamTransport.close_stream(state.stream_transport, error.error_code)
  end

  def terminate({%Errors.ConnectionError{} = error, _stacktrace}, state) do
    Bandit.Telemetry.stop_span(state.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target
    })

    StreamTransport.close_connection(state.stream_transport, error.error_code, error.message)
  end

  def terminate({exception, stacktrace}, state) do
    Bandit.Telemetry.span_exception(state.span, :exit, exception, stacktrace)
    StreamTransport.close_stream(state.stream_transport, Errors.internal_error())
  end
end
