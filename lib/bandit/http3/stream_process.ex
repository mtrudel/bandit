defmodule Bandit.HTTP3.StreamProcess do
  @moduledoc false
  # This process runs the lifecycle of an HTTP/3 stream, which is modeled by a
  # `Bandit.HTTP3.Stream` struct that this process maintains in its state.
  #
  # As part of this lifecycle, the execution of a Plug to handle this stream's
  # request takes place here; the entirety of the Plug lifecycle takes place in
  # a single `c:handle_continue/2` call, mirroring the HTTP/2 pattern.

  use GenServer, restart: :temporary

  @spec start_link(
          Bandit.HTTP3.Stream.t(),
          Bandit.Pipeline.plug_def(),
          Bandit.Telemetry.t(),
          Bandit.Pipeline.conn_data(),
          map()
        ) :: GenServer.on_start()
  def start_link(stream, plug, connection_span, conn_data, opts) do
    GenServer.start_link(__MODULE__, {stream, plug, connection_span, conn_data, opts})
  end

  @impl GenServer
  def init(state), do: {:ok, state, {:continue, :start_stream}}

  @impl GenServer
  def handle_continue(:start_stream, {stream, plug, connection_span, conn_data, opts} = state) do
    _ = Bandit.Pipeline.run(stream, plug, connection_span, conn_data, opts)
    {:stop, :normal, state}
  end
end
