defmodule Bandit.HTTP2.StreamProcess do
  @moduledoc false
  # This process runs the lifecycle of an HTTP/2 stream, which is modeled by a
  # `Bandit.HTTP2.Stream` struct that this process maintains in its state
  #
  # As part of this lifecycle, the execution of a Plug to handle this stream's request
  # takes place here; the entirety of the Plug lifecycle takes place in a single
  # `c:handle_stream/5` call.

  @spec start_link(
          Bandit.HTTP2.Stream.t(),
          Bandit.Pipeline.plug_def(),
          Bandit.Telemetry.t(),
          Bandit.Pipeline.conn_data(),
          keyword()
        ) :: {:ok, pid()}
  def start_link(stream, plug, connection_span, conn_data, opts) do
    Task.start_link(__MODULE__, :handle_stream, [stream, plug, connection_span, conn_data, opts])
  end

  def handle_stream(stream, plug, connection_span, conn_data, opts) do
    _ = Bandit.Pipeline.run(stream, plug, connection_span, conn_data, opts)
    :ok
  end
end
