defmodule ClockTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Bandit.Util

  test "clock emits warning if ETS cache isn't available" do
    Application.stop(:bandit)

    warnings =
      capture_log(fn ->
        {"date", date} = Bandit.Clock.date_header()
        assert DateHelpers.valid_date_header?(date)
      end)

    assert warnings =~ "Header timestamp couldn't be fetched from ETS cache"

    Application.ensure_all_started(:bandit)
  end

  test "clock process gets labeled" do
    if Util.labels_supported?() do
      Process.sleep(100)

      processes = Process.list()

      labeled_processes =
        for pid <- processes,
            Util.get_label(pid) == Bandit.Clock do
          {pid, Bandit.Clock}
        end

      assert length(labeled_processes) >= 1
    end
  end
end
