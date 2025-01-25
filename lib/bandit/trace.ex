defmodule Bandit.Trace do
  @moduledoc """
  **THIS MODULE IS EXPERIMENTAL AND SUBJECT TO CHANGE**

  Helper functions to provide visibility into runtime errors within a running Bandit instance

  Can be used within an IEx session attached to a running Bandit instance, as follows:

  ```
  iex> Bandit.Trace.start_tracing()
  ... # Wait for traces to show up whenever exceptions are raised
  iex> Bandit.Trace.stop_tracing()
  ```

  It can also be started within your application by adding `Bandit.Trace` to your process tree.

  `Bandit.Trace` will emit a trace on every exception that Bandit sees (both those emitted from
  within your Plug as well as internal ones due to protocol violations and the like). These traces
  consist of a complete dump of all telemetry events that occur in the offending request's parent
  connection.

  Tracing imposes a modest but non-zero load; it *should* be safe to run in most production
  environments, but it is not intended to run on an ongoing basis.

  By default, `Bandit.Trace` maintains a FIFO log of the last 10000 telemetry events that Bandit
  has emitted. Events which correlate to the parent connection which have been evicted from this
  queue will not be included in this output.

  **WARNING** The emitted logs contains a *complete* copy of your request's Plug data, as well as *all* data
  sent and received on all requests which are contained in the output. It is therefore of the utmost
  importance that you carefully redact the output before sharing it publicly.
  """

  defstruct queue: nil, size: 0, max_size: 10_000, trace_on_exception: true

  use GenServer

  require Logger

  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception],
    [:bandit, :websocket, :start],
    [:bandit, :websocket, :stop],
    [:thousand_island, :connection, :start],
    [:thousand_island, :connection, :stop],
    [:thousand_island, :connection, :ready],
    [:thousand_island, :connection, :async_recv],
    [:thousand_island, :connection, :recv],
    [:thousand_island, :connection, :recv_error],
    [:thousand_island, :connection, :send],
    [:thousand_island, :connection, :send_error],
    [:thousand_island, :connection, :sendfile],
    [:thousand_island, :connection, :sendfile_error],
    [:thousand_island, :connection, :socket_shutdown]
  ]

  @doc """
  Start tracing of all Bandit requests

  See module documentation for intended usage. Accepts the following options:

  * `max_size`: The size of the telemetry event queue to maintain. By default, `Bandit.Trace` maintains a
    queue of the last 10000 telemetry events
  * `trace_on_exception`: Whether or not to emit traces when an error is raised within
    Bandit. Defaults to `true`
  """
  def start_tracing(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Stop any active trace session
  """
  def stop_tracing, do: GenServer.stop(__MODULE__)

  def handle_event(event, measurements, metadata, pid),
    do: GenServer.cast(pid, {:event, {event, measurements, metadata, :os.perf_counter()}})

  @doc """
  Return the complete queue of telemetry events that `Bandit.Trace` is currently tracking
  """
  def get_events, do: GenServer.call(__MODULE__, :get_events)

  @impl GenServer
  def init(opts) do
    _ = :telemetry.attach_many(self(), @events, &__MODULE__.handle_event/4, self())
    {:ok, struct!(%__MODULE__{queue: :queue.new()}, opts)}
  end

  @impl GenServer
  def terminate(_, _), do: :telemetry.detach(self())

  @impl GenServer
  def handle_cast({:event, event}, state) do
    state
    |> maybe_pop()
    |> push(event)
    |> tap(&maybe_trace(&1, event))
    |> then(&{:noreply, &1})
  end

  defp maybe_pop(%{size: size, max_size: max_size} = state) when size >= max_size,
    do: maybe_pop(%{state | queue: :queue.drop(state.queue), size: size - 1})

  defp maybe_pop(state), do: state

  defp push(state, event),
    do: %{state | queue: :queue.in(event, state.queue), size: state.size + 1}

  defp maybe_trace(
         %{trace_on_exception: true} = state,
         {[:bandit, :request, :exception], _, metadata, _}
       ) do
    connection_span_context = Map.get(metadata, :connection_telemetry_span_context)

    IO.puts("======================================")
    IO.puts("Starting telemetry trace for exception")
    IO.puts("======================================")

    :queue.to_list(state.queue)
    |> Enum.filter(fn {_, _, metadata, _} ->
      Map.get(metadata, :telemetry_span_context) == connection_span_context ||
        Map.get(metadata, :connection_telemetry_span_context) == connection_span_context
    end)
    |> format_list()
    |> inspect(limit: :infinity, pretty: true, printable_limit: :infinity)
    |> IO.puts()

    IO.puts("=======================================")
    IO.puts("Completed telemetry trace for exception")
    IO.puts("=======================================")

    :ok
  end

  defp maybe_trace(_state, _event), do: :ok

  @impl GenServer
  def handle_call(:get_events, _from, state),
    do: {:reply, :queue.to_list(state.queue) |> format_list(), state}

  defp format_list([]), do: :ok

  defp format_list([{_, _, _, start_time} | _] = events),
    do: Enum.map(events, &format_tuple(&1, start_time))

  defp format_tuple({event, measurements, metadata, time}, start_time) do
    time = :erlang.convert_time_unit(time - start_time, :perf_counter, :microsecond)
    %{telemetry_span_context: span_id} = metadata
    {time, span_id, event, measurements, metadata}
  end
end
