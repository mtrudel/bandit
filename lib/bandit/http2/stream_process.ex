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
          Bandit.Telemetry.t(),
          keyword()
        ) :: GenServer.on_start()
  def start_link(stream, plug, connection_span, opts) do
    GenServer.start_link(__MODULE__, {stream, plug, connection_span, opts})
  end

  @impl GenServer
  def init(state), do: {:ok, state, {:continue, :start_stream}}

  @impl GenServer
  def handle_continue(:start_stream, {stream, plug, connection_span, opts} = state) do
    _ = Bandit.Pipeline.run(stream, plug, connection_span, opts)
    {:stop, :normal, state}
  end
end
