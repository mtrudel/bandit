defmodule WebsocketAutobahnTest do
  use ExUnit.Case, async: false

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @moduletag :external_conformance
  @moduletag timeout: 600_000

  defmodule EchoSock do
    use NoopSock
    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
  end

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> Bandit.WebSocket.Handshake.handshake?()
    |> case do
      true -> Plug.Conn.upgrade_adapter(conn, :websocket, {EchoSock, :ok, []})
      false -> Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  @tag capture_log: true
  test "autobahn test suite" do
    # We need to be on port 4000, so start server with a handmade spec
    Bandit.child_spec(plug: __MODULE__) |> start_supervised!()

    {_, 0} =
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "-v",
          "#{Path.join(__DIR__, "../../support/autobahn_config.json")}:/fuzzingclient.json",
          "-v",
          "#{Path.join(__DIR__, "../../support/autobahn_reports")}:/reports"
        ] ++
          cmds() ++
          [
            "--name",
            "fuzzingclient",
            "crossbario/autobahn-testsuite",
            "wstest",
            "--mode",
            "fuzzingclient"
          ],
        stderr_to_stdout: true
      )

    failures =
      Path.join(__DIR__, "../../support/autobahn_reports/servers/index.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("bandit")
      |> Enum.map(fn {test_case, %{"behavior" => res, "behaviorClose" => res_close}} ->
        {test_case, res, res_close}
      end)
      |> Enum.reject(fn {_, res, res_close} ->
        (res == "OK" or res == "NON-STRICT" or res == "INFORMATIONAL") and
          (res_close == "OK" or res_close == "INFORMATIONAL")
      end)
      |> Enum.sort_by(fn {code, _, _} -> code end)

    assert failures == []
  end

  if :os.type() == {:unix, :linux} do
    defp cmds do
      ["--add-host=host.docker.internal:host-gateway"]
    end
  else
    defp cmds do
      []
    end
  end
end
