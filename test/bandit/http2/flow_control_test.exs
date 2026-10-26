defmodule HTTP2FlowControlTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.FlowControl

  describe "stream_recv_window_target/1" do
    test "is never smaller than the initial window" do
      assert FlowControl.stream_recv_window_target(65_535) == 1_048_576
      assert FlowControl.stream_recv_window_target(4_000_000) == 4_000_000
    end
  end

  describe "compute_recv_window/3" do
    test "does not update while more than half of the target remains" do
      assert FlowControl.compute_recv_window(1_000_000, 400_000, 1_048_576) ==
               {600_000, 0}
    end

    test "tops the window back up to the target once it falls to half" do
      assert FlowControl.compute_recv_window(600_000, 100_000, 1_048_576) ==
               {1_048_576, 548_576}
    end

    test "tops the window up when it starts below the target" do
      assert FlowControl.compute_recv_window(65_535, 1, 1_048_576) ==
               {1_048_576, 983_042}
    end
  end
end
