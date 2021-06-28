defmodule HTTP2FrameDeserializationTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.{Constants, Frame}

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
    @tag capture_log: true
    test "returns a nil frame" do
      frame = <<0, 0, 3, 254, 0, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.deserialize(frame) == {{:ok, nil}, <<>>}
    end
  end

  describe "DATA frames" do
    test "deserializes frames with padding" do
      frame = <<0, 0, 6, 0, 0x08, 0, 0, 0, 1, 2, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: false, data: <<1, 2, 3>>}}, <<>>}
    end

    test "deserializes frames without padding" do
      frame = <<0, 0, 3, 0, 0, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: false, data: <<1, 2, 3>>}}, <<>>}
    end

    test "sets end_stream" do
      frame = <<0, 0, 3, 0, 0x01, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: true, data: <<1, 2, 3>>}}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 3, 0, 0, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "DATA frame with zero stream_id (RFC7540§6.1)"}, <<>>}
    end

    test "rejects frames with invalid padding" do
      frame = <<0, 0, 6, 0, 0x08, 0, 0, 0, 1, 6, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "DATA frame with invalid padding length (RFC7540§6.1)"}, <<>>}
    end
  end

  describe "HEADERS frames" do
    test "deserializes frames with padding and priority" do
      frame = <<0, 0, 11, 1, 0x28, 0, 0, 0, 1, 2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: false,
                   end_headers: false,
                   exclusive_dependency: true,
                   stream_dependency: 12,
                   weight: 34,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "deserializes frames with padding but not priority" do
      frame = <<0, 0, 6, 1, 0x08, 0, 0, 0, 1, 2, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: false,
                   end_headers: false,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "deserializes frames with priority but not padding" do
      frame = <<0, 0, 8, 1, 0x20, 0, 0, 0, 1, 0::1, 12::31, 34, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: false,
                   end_headers: false,
                   exclusive_dependency: false,
                   stream_dependency: 12,
                   weight: 34,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "deserializes frames with neither priority nor padding" do
      frame = <<0, 0, 3, 1, 0x00, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: false,
                   end_headers: false,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "sets end_stream" do
      frame = <<0, 0, 3, 1, 0x01, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: true,
                   end_headers: false,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "sets end_headers" do
      frame = <<0, 0, 3, 1, 0x04, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Headers{
                   stream_id: 1,
                   end_stream: false,
                   end_headers: true,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 3, 1, 0x04, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "HEADERS frame with zero stream_id (RFC7540§6.2)"}, <<>>}
    end

    test "rejects frames with invalid padding and priority" do
      frame = <<0, 0, 11, 1, 0x28, 0, 0, 0, 1, 6, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "HEADERS frame with invalid padding length (RFC7540§6.2)"}, <<>>}
    end

    test "rejects frames with invalid padding and not priority" do
      frame = <<0, 0, 6, 1, 0x08, 0, 0, 0, 1, 6, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "HEADERS frame with invalid padding length (RFC7540§6.2)"}, <<>>}
    end
  end

  describe "RST_STREAM frames" do
    test "deserializes frames" do
      frame = <<0, 0, 4, 3, 0, 0, 0, 0, 1, 0, 0, 0, 123>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.RstStream{stream_id: 1, error_code: 123}}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0, 123>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 1, "RST_STREAM frame with zero stream_id (RFC7540§6.4)"}, <<>>}
    end

    test "rejects frames with invalid size" do
      frame = <<0, 0, 5, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 123>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, 6, "Invalid payload size in RST_STREAM frame (RFC7540§6.4)"}, <<>>}
    end
  end

  describe "SETTINGS frames" do
    test "deserializes non-ack frames when there are no contained settings" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Settings{ack: false, settings: %{}}}, <<>>}
    end

    test "deserializes non-ack frames when there are contained settings" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 255>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Settings{ack: false, settings: %{1 => 255}}}, <<>>}
    end

    test "rejects non-ack frames when there is a malformed payload" do
      frame = <<0, 0, 1, 4, 0, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.frame_size_error(),
                 "Invalid SETTINGS payload (RFC7540§6.5)"}, <<>>}
    end

    test "rejects non-ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.protocol_error(), "Invalid SETTINGS frame (RFC7540§6.5)"},
                <<>>}
    end

    test "deserializes ack frames" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 0>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Settings{ack: true, settings: %{}}}, <<>>}
    end

    test "rejects ack frames when there is a payload" do
      frame = <<0, 0, 1, 4, 1, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.frame_size_error(),
                 "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}, <<>>}
    end

    test "rejects ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.protocol_error(), "Invalid SETTINGS frame (RFC7540§6.5)"},
                <<>>}
    end
  end

  describe "PING frames" do
    test "deserializes non-ack frames" do
      frame = <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Ping{ack: false, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "deserializes ack frames" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Ping{ack: true, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 7, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.frame_size_error(),
                 "PING frame with invalid payload size (RFC7540§6.7)"}, <<>>}
    end

    test "rejects frames when there is stream identifier" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.protocol_error(),
                 "Invalid stream ID in PING frame (RFC7540§6.7)"}, <<>>}
    end
  end

  describe "GOAWAY frames" do
    test "deserializes frames without debug data" do
      frame = <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<>>}}, <<>>}
    end

    test "deserializes frames with debug data" do
      frame = <<0, 0, 10, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 3, 4>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<3, 4>>}},
                <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 7, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.frame_size_error(),
                 "GOAWAY frame with invalid payload size (RFC7540§6.8)"}, <<>>}
    end

    test "rejects frames when there is stream identifier" do
      frame = <<0, 0, 7, 7, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0>>

      assert Frame.deserialize(frame) ==
               {{:error, 0, Constants.protocol_error(),
                 "Invalid stream ID in GOAWAY frame (RFC7540§6.8)"}, <<>>}
    end
  end

  describe "CONTINUATION frames" do
    test "deserializes frames" do
      frame = <<0, 0, 3, 9, 0x00, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Continuation{
                   stream_id: 1,
                   end_headers: false,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "sets end_headers" do
      frame = <<0, 0, 3, 9, 0x04, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok,
                 %Frame.Continuation{
                   stream_id: 1,
                   end_headers: true,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end
  end
end
