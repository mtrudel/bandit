defmodule HTTP2FrameDeserializationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Bandit.HTTP2.Frame

  describe "insufficient data" do
    test "asks for more" do
      frame = <<0, 0, 0, 4>>

      assert Frame.deserialize(frame) == {{:more, <<0, 0, 0, 4>>}, <<>>}
    end

    test "ends the stream when empty" do
      frame = <<>>

      assert Frame.deserialize(frame) == nil
    end
  end

  describe "extra data" do
    test "returns extra data" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Settings{}}, <<1, 2, 3>>}
    end
  end

  describe "unknown frame types" do
    test "returns a nil frame" do
      frame = <<0, 0, 3, 254, 0, 0, 0, 0, 0, 1, 2, 3>>

      capture_log(fn ->
        assert Frame.deserialize(frame) == {{:ok, nil}, <<>>}
      end)
    end
  end

  describe "SETTINGS frames" do
    test "builds non-ack frames when there are no contained settings" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Settings{ack: false, settings: %{}}}, <<>>}
    end

    test "builds non-ack frames when there are contained settings" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 255>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Settings{ack: false, settings: %{1 => 255}}}, <<>>}
    end

    test "rejects non-ack frames when there is a malformed payload" do
      frame = <<0, 0, 1, 4, 0, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, :FRAME_SIZE_ERROR, "Invalid SETTINGS payload (RFC7540§6.5)"}, <<>>}
    end

    test "rejects non-ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, :PROTOCOL_ERROR, "Invalid SETTINGS frame (RFC7540§6.5)"}, <<>>}
    end

    test "builds ack frames" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 0>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Settings{ack: true, settings: %{}}}, <<>>}
    end

    test "rejects ack frames when there is a payload" do
      frame = <<0, 0, 1, 4, 1, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, :FRAME_SIZE_ERROR,
                 "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}, <<>>}
    end
  end

  describe "PING frames" do
    test "builds non-ack frames" do
      frame = <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Ping{ack: false, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "builds ack frames" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Ping{ack: true, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 7, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, :FRAME_SIZE_ERROR,
                 "PING frame with invalid payload size (RFC7540§6.7)"}, <<>>}
    end

    test "rejects frames when there is stream identifier" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, :PROTOCOL_ERROR, "Invalid stream ID in PING frame (RFC7540§6.7)"},
                <<>>}
    end
  end
end
