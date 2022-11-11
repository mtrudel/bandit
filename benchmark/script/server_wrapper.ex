defmodule ServerWrapper do
  # This module is not intended to be called directly from within the containing
  # mix project. It uses `Mix.install` to install and run arbitrary servers in a
  # separate OS process. It is intended to be run like so:
  #
  # > elixir script/server_wrapper.ex bandit main 4000
  #

  def run([server, treeish, port]) do
    install_packages(server, treeish)
    start_server(server, String.to_integer(port))
    Process.sleep(:infinity)
  end

  defp install_packages("bandit", "local") do
    {:bandit, path: "../"}
    |> do_install()
  end

  defp install_packages("bandit", treeish) do
    {:bandit, github: "mtrudel/bandit", ref: treeish}
    |> do_install()
  end

  defp install_packages("cowboy", treeish) do
    {:plug_cowboy, github: "elixir-plug/plug_cowboy", ref: treeish}
    |> do_install()
  end

  defp install_packages(server, treeish) do
    raise "Don't know how to install #{server} (#{treeish})"
  end

  defp do_install(dep) do
    Mix.install([{:benchmark, path: "."}, dep])
  end

  defp start_server("bandit", port) do
    apply(Bandit, :start_link, [[plug: Benchmark.Echo, options: [port: port]]])
  end

  defp start_server("cowboy", port) do
    apply(Plug.Cowboy, :http, [Benchmark.Echo, [], [port: port]])
  end
end

ServerWrapper.run(System.argv())
