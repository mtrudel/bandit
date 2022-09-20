defmodule ServerTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  import ExUnit.CaptureLog

  test "server logs connection details at startup" do
    logs =
      capture_log(fn ->
        [
          plug: __MODULE__,
          sock: __MODULE__,
          options: [port: 0, transport_options: [ip: :loopback]]
        ]
        |> Bandit.child_spec()
        |> start_supervised()
      end)

    assert logs =~
             "Running plug: ServerTest, sock: ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at 127.0.0.1"
  end
end
