defmodule HTTP2FrameParsingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Bandit.HTTP2.Frame

  describe "insufficient data" do
    test "asks for more" do
      frame = <<0, 0, 0, 4>>

      assert Frame.parse(frame) == {:more, <<0, 0, 0, 4>>}
    end
  end

  describe "extra data" do
    test "returns extra data" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.parse(frame) == {:ok, %Frame.Setting{}, <<1, 2, 3>>}
    end
  end

  describe "unknown frame types" do
    test "returns a nil frame" do
      frame = <<0, 0, 3, 254, 0, 0, 0, 0, 0, 1, 2, 3>>

      capture_log(fn ->
        assert Frame.parse(frame) == {:ok, nil, <<>>}
      end)
    end
  end

  describe "SETTINGS frames" do
    test "builds non-ack frames when there are no contained settings" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0>>

      assert Frame.parse(frame) == {:ok, %Frame.Setting{ack: false, settings: %{}}, <<>>}
    end

    test "builds non-ack frames when there are contained settings" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 255>>

      assert Frame.parse(frame) == {:ok, %Frame.Setting{ack: false, settings: %{1 => 255}}, <<>>}
    end

    test "rejects non-ack frames when there is a malformed payload" do
      frame = <<0, 0, 1, 4, 0, 0, 0, 0, 0, 1>>

      assert Frame.parse(frame) ==
               {:error, 0, :FRAME_SIZE_ERROR, "Invalid SETTINGS payload (RFC7540§6.5)"}
    end

    test "rejects non-ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 1>>

      assert Frame.parse(frame) ==
               {:error, 0, :PROTOCOL_ERROR, "Invalid SETTINGS frame (RFC7540§6.5)"}
    end

    test "builds ack frames" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 0>>

      assert Frame.parse(frame) == {:ok, %Frame.Setting{ack: true, settings: %{}}, <<>>}
    end

    test "rejects ack frames when there is a payload" do
      frame = <<0, 0, 1, 4, 1, 0, 0, 0, 0, 1>>

      assert Frame.parse(frame) ==
               {:error, 0, :FRAME_SIZE_ERROR,
                "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}
    end
  end
end
