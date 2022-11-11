defmodule Benchmark do
  def run(server, treeish, host \\ ~c"localhost", port \\ 4000)
      when server in ~w[bandit cowboy] do
    running("elixir", ["script/server_wrapper.ex", server, treeish, to_string(port)], fn ->
      wait_for_server(host, port, 60_000)
      Benchmark.HTTPClient.run(server: server, treeish: treeish)
    end)
  end

  if Code.ensure_loaded?(MuonTrap.Daemon) do
    defp running(cmd, argv, func) do
      {:ok, pid} = MuonTrap.Daemon.start_link(cmd, argv)
      result = func.()
      GenServer.stop(pid)
      result
    end
  else
    defp running(_cmd, _argv, _func), do: raise("unsupported")
  end

  defp wait_for_server(_host, _port, 0), do: raise("Timeout waiting for server to be ready")

  defp wait_for_server(host, port, count) do
    case :gen_tcp.connect(host, port, active: false, mode: :binary) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        IO.puts("ready")
        Process.sleep(500)

      _ ->
        IO.write(".")
        Process.sleep(100)
        wait_for_server(host, port, count - 100)
    end
  end
end
