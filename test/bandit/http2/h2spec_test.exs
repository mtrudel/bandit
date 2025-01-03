defmodule H2SpecTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  @moduletag :external_conformance
  @moduletag timeout: 600_000

  setup :https_server

  def hello_world(conn) do
    conn |> send_resp(200, "OK")
  end

  @tag :capture_log
  test "passes h2spec", context do
    {cmd, opts} =
      case System.find_executable("h2spec") do
        path when is_binary(path) -> {path, []}
        nil -> {"docker", ["run", "--network=host", "summerwind/h2spec"]}
      end

    opts = if System.get_env("H2SPEC"), do: [System.get_env("H2SPEC") | opts], else: opts

    opts =
      opts ++ ["-p", Integer.to_string(context.port), "--path", "/hello_world", "-tk", "--strict"]

    {result, status} = System.cmd(cmd, opts)

    assert status == 0, "h2spec had errors:\n#{result}"
  end
end
