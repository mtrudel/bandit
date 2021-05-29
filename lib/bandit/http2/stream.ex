defmodule Bandit.HTTP2.Stream do
  @moduledoc false

  use Task

  def start_link(connection, stream_id, peer, headers, plug) do
    Task.start_link(__MODULE__, :run, [connection, stream_id, peer, headers, plug])
  end

  def run(connection, stream_id, peer, headers, plug) do
    IO.puts(
      "Processing s: #{stream_id}, p: #{inspect(peer)}, p: #{inspect(plug)}, h: #{inspect(headers)}"
    )
  end
end
