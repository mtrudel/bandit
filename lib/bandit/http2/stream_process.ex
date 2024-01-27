defmodule Bandit.HTTP2.StreamProcess do
  @moduledoc false
  # This process runs the lifecycle of an HTTP/2 stream, which is modeled by a
  # `Bandit.HTTP2.Stream` struct that this process maintains in its state
  #
  # As part of this lifecycle, the execution of a Plug to handle this stream's request
  # takes place here; the entirety of the Plug lifecycle takes place in a single
  # `c:handle_continue/2` call.

  use GenServer, restart: :temporary

  @spec start_link(
          Bandit.HTTP2.Stream.t(),
          Bandit.Pipeline.plug_def(),
          keyword(),
          Bandit.Telemetry.t()
        ) :: GenServer.on_start()
  def start_link(stream, plug, opts, connection_span) do
    GenServer.start_link(__MODULE__, {stream, plug, opts, connection_span})
  end

  @impl GenServer
  def init({stream, plug, opts, connection_span}) do
    span =
      Bandit.Telemetry.start_span(:request, %{}, %{
        connection_telemetry_span_context: connection_span.telemetry_span_context,
        stream_id: stream.stream_id
      })

    {:ok, %{stream: stream, plug: plug, opts: opts, span: span}, {:continue, :start_stream}}
  end

  @impl GenServer
  def handle_continue(:start_stream, state) do
    {:ok, method, request_target, headers, stream} =
      Bandit.HTTP2.Stream.read_headers(state.stream)

    adapter =
      {Bandit.HTTP2.Adapter,
       Bandit.HTTP2.Adapter.init(stream, method, headers, self(), state.opts)}

    transport_info = state.stream.transport_info

    case Bandit.Pipeline.run(adapter, transport_info, method, request_target, headers, state.plug) do
      {:ok, %Plug.Conn{adapter: {Bandit.HTTP2.Adapter, req}} = conn} ->
        stream = Bandit.HTTP2.Stream.ensure_completed(req.stream)

        Bandit.Telemetry.stop_span(state.span, req.metrics, %{
          conn: conn,
          method: method,
          request_target: request_target,
          status: conn.status
        })

        {:stop, :normal, %{state | stream: stream}}

      {:error, reason} ->
        raise Bandit.HTTP2.Errors.StreamError,
          message: reason,
          error_code: Bandit.HTTP2.Errors.internal_error()
    end
  end

  @impl GenServer
  def terminate(:normal, _state), do: :ok

  def terminate({%Bandit.HTTP2.Errors.StreamError{} = error, _stacktrace}, state) do
    Bandit.Telemetry.stop_span(state.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target
    })

    Bandit.HTTP2.Stream.reset_stream(state.stream, error.error_code)
  end

  def terminate({%Bandit.HTTP2.Errors.ConnectionError{} = error, _stacktrace}, state) do
    Bandit.Telemetry.stop_span(state.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target
    })

    Bandit.HTTP2.Stream.close_connection(state.stream, error.error_code, error.message)
  end

  def terminate({exception, stacktrace}, state) do
    Bandit.Telemetry.span_exception(state.span, :exit, exception, stacktrace)
    Bandit.HTTP2.Stream.reset_stream(state.stream, Bandit.HTTP2.Errors.internal_error())
  end
end
