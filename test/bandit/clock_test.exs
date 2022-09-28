defmodule ClockTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "clock emits warning if ETS cache isn't available" do
    Application.stop(:bandit)

    warnings =
      capture_log(fn ->
        Bandit.Clock.date_header()
      end)

    assert warnings =~ "Header timestamp couldn't get fetched from ETS cache."

    Application.ensure_all_started(:bandit)
  end
end
