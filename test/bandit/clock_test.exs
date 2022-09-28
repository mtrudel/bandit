defmodule ClockTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import TestHelpers

  test "clock emits warning if ETS cache isn't available" do
    Application.stop(:bandit)

    warnings =
      capture_log(fn ->
        {"date", date} = Bandit.Clock.date_header()
        assert valid_date_header?(date)
      end)

    assert warnings =~ "Header timestamp couldn't be fetched from ETS cache"

    Application.ensure_all_started(:bandit)
  end
end
