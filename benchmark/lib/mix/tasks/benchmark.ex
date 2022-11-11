defmodule Mix.Tasks.Benchmark do
  @moduledoc "Runs benchmarks against specific HTTP servers"
  @shortdoc "Runs benchmarks against specific HTTP servers"

  use Mix.Task

  @impl Mix.Task
  def run([server]), do: run([server, nil])

  def run([server, filename]) do
    [server, treeish] =
      case String.split(server, "@") do
        [server, treeish] -> [server, treeish]
        ["bandit"] -> ["bandit", "local"]
        ["cowboy"] -> ["cowboy", "master"]
      end

    filename = filename || "#{server}-#{treeish}.json"
    File.write!(filename, Benchmark.run(server, treeish) |> Jason.encode!(pretty: true))
  end

  def run(_) do
    Mix.Shell.IO.error(
      "usage: mix benchmark <bandit[@(treeish | local)] | cowboy[@treeish]> [filename.json]"
    )
  end
end
