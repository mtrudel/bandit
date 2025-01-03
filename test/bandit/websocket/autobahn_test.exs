defmodule WebsocketAutobahnTest do
  use ExUnit.Case, async: true

  @moduletag :slow
  @moduletag timeout: 3_600_000

  defmodule EchoWebSock do
    use NoopWebSock
    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
  end

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {EchoWebSock, :ok, compress: true})
  end

  @tag :capture_log
  test "autobahn test suite" do
    # We can't use ServerHelpers since we need to bind on all interfaces
    {:ok, server_pid} = start_supervised({Bandit, plug: __MODULE__, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server_pid)

    random_string = :rand.uniform(0x100000000) |> Integer.to_string(36) |> String.downcase()
    tmp_path = Path.join(System.tmp_dir!(), "autobahn-#{random_string}")
    File.mkdir_p(Path.join(tmp_path, "reports"))

    Path.join(tmp_path, "fuzzingclient.json")
    |> File.open!([:write, :utf8], fn file ->
      IO.write(
        file,
        %{
          outdir: "./reports",
          cases: (System.get_env("AUTOBAHN_CASES") || "*") |> String.split(","),
          "exclude-cases": (System.get_env("AUTOBAHN_EXCLUDE_CASES") || "") |> String.split(","),
          "exclude-agent-cases": %{}
        }
        |> Jason.encode!()
      )
    end)

    output =
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "-v",
          "#{Path.join(tmp_path, "fuzzingclient.json")}:/fuzzingclient.json",
          "-v",
          "#{Path.join(tmp_path, "reports")}:/reports"
        ] ++
          extra_args() ++
          [
            "--name",
            "fuzzingclient",
            "crossbario/autobahn-testsuite",
            "wstest",
            "--mode",
            "fuzzingclient",
            "-w",
            "ws://host.docker.internal:#{port}"
          ],
        stderr_to_stdout: true
      )

    assert {_, 0} = output

    failures =
      Path.join(tmp_path, "reports/index.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("UnknownServer")
      |> Enum.map(fn {test_case, %{"behavior" => res, "behaviorClose" => res_close}} ->
        {test_case, res, res_close}
      end)
      |> Enum.reject(fn {_, res, res_close} ->
        (res == "OK" or res == "NON-STRICT" or res == "INFORMATIONAL") and
          (res_close == "OK" or res_close == "INFORMATIONAL")
      end)
      |> Enum.sort_by(fn {code, _, _} -> code end)

    File.rmdir(tmp_path)

    assert [] = failures
  end

  defp extra_args do
    case :os.type() do
      {:unix, :linux} -> ["--add-host=host.docker.internal:host-gateway"]
      _ -> []
    end
  end
end
