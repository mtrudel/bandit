defmodule H2SpecTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  @moduletag :slow
  @moduletag timeout: 600_000

  # Several h2spec cases wait for the server to close an idle connection, which it must do
  # inside h2spec's own timeout of two seconds
  @moduletag read_timeout: 100

  setup :https_server

  # The request body is read before the response is sent. h2spec case 6.9.1/3 opens a stream,
  # leaves its request body open, and then sends WINDOW_UPDATE frames which overflow the stream's
  # window. If the response had already gone out the stream would be closed, and the server would
  # be right to ignore those frames (RFC9113§5.1), which h2spec counts as a failure
  def hello_world(conn) do
    {:ok, _body, conn} = read_body(conn)
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
