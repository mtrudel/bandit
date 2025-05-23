defmodule HTTP2FrameDeserializationTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.{Errors, Frame}

  describe "insufficient data" do
    test "asks for more" do
      frame = <<0, 0, 0, 4>>

      assert Frame.deserialize(frame, 16_384) == {{:more, <<0, 0, 0, 4>>}, <<>>}
    end

    test "ends the stream when empty" do
      frame = <<>>

      assert Frame.deserialize(frame, 16_384) == nil
    end
  end

  describe "extra data" do
    test "returns extra data" do
      frame = <<0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Data{stream_id: 1, data: <<>>}}, <<1, 2, 3>>}
    end
  end

  describe "unknown frame types" do
    test "returns an Unknown frame" do
      frame = <<0, 0, 3, 254, 123, 0, 0, 0, 234, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok,
                 %Frame.Unknown{type: 254, flags: 123, stream_id: 234, payload: <<1, 2, 3>>}},
                <<>>}
    end
  end

  describe "DATA frames" do
    test "deserializes frames with padding" do
      frame = <<0, 0, 6, 0, 0x08, 0, 0, 0, 1, 2, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: false, data: <<1, 2, 3>>}}, <<>>}
    end

    test "deserializes frames without padding" do
      frame = <<0, 0, 3, 0, 0, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: false, data: <<1, 2, 3>>}}, <<>>}
    end

    test "sets end_stream" do
      frame = <<0, 0, 3, 0, 0x01, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Data{stream_id: 1, end_stream: true, data: <<1, 2, 3>>}}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 3, 0, 0, 0, 0, 0, 0, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "DATA frame with zero stream_id (RFC9113§6.1)"}, <<>>}
    end

    test "rejects frames with invalid padding" do
      frame = <<0, 0, 6, 0, 0x08, 0, 0, 0, 1, 6, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "DATA frame with invalid padding length (RFC9113§6.1)"}, <<>>}
    end
  end

  describe "HEADERS frames" do
    test "deserializes frames with padding and priority" do
      frame = <<0, 0, 11, 1, 0x28, 0, 0, 0, 1, 2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
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

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "HEADERS frame with zero stream_id (RFC9113§6.2)"}, <<>>}
    end

    test "rejects frames with invalid padding and priority" do
      frame = <<0, 0, 11, 1, 0x28, 0, 0, 0, 1, 6, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "HEADERS frame with invalid padding length (RFC9113§6.2)"}, <<>>}
    end

    test "rejects frames with invalid padding and not priority" do
      frame = <<0, 0, 6, 1, 0x08, 0, 0, 0, 1, 6, 1, 2, 3, 4, 5>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "HEADERS frame with invalid padding length (RFC9113§6.2)"}, <<>>}
    end
  end

  describe "PRIORITY frames" do
    test "deserializes frames" do
      frame = <<0, 0, 5, 2, 0, 0, 0, 0, 1, 0, 0, 0, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Priority{stream_id: 1, dependent_stream_id: 2, weight: 3}}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "PRIORITY frame with zero stream_id (RFC9113§6.3)"}, <<>>}
    end

    test "rejects frames with invalid size" do
      frame = <<0, 0, 6, 2, 0, 0, 0, 0, 1, 0, 0, 0, 2, 3, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 6, "Invalid payload size in PRIORITY frame (RFC9113§6.3)"}, <<>>}
    end
  end

  describe "RST_STREAM frames" do
    test "deserializes frames" do
      frame = <<0, 0, 4, 3, 0, 0, 0, 0, 1, 0, 0, 0, 123>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.RstStream{stream_id: 1, error_code: 123}}, <<>>}
    end

    test "rejects frames with 0 stream_id" do
      frame = <<0, 0, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0, 123>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "RST_STREAM frame with zero stream_id (RFC9113§6.4)"}, <<>>}
    end

    test "rejects frames with invalid size" do
      frame = <<0, 0, 5, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 123>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 6, "Invalid payload size in RST_STREAM frame (RFC9113§6.4)"}, <<>>}
    end
  end

  describe "SETTINGS frames" do
    test "deserializes non-ack frames when there are no non-default settings" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Settings{ack: false, settings: %{}}}, <<>>}
    end

    test "deserializes non-ack frames when there are non-default settings" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 255>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Settings{ack: false, settings: %{header_table_size: 255}}}, <<>>}
    end

    test "rejects non-ack frames when there is a malformed payload" do
      frame = <<0, 0, 1, 4, 0, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(), "Invalid SETTINGS size (RFC9113§6.5)"}, <<>>}
    end

    test "rejects non-ack frames with invalid enable_push_promise value" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.protocol_error(), "Invalid enable_push value (RFC9113§6.5)"},
                <<>>}
    end

    test "rejects non-ack frames with invalid initial_window_size value" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 4, 255, 255, 255, 255>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.flow_control_error(), "Invalid window_size (RFC9113§6.5)"}, <<>>}
    end

    test "rejects non-ack frames with invalid large max_frame_size value" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 5, 255, 255, 255, 255>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(), "Invalid max_frame_size (RFC9113§6.5)"}, <<>>}
    end

    test "rejects non-ack frames with invalid small max_frame_size value" do
      frame = <<0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(), "Invalid max_frame_size (RFC9113§6.5)"}, <<>>}
    end

    test "rejects non-ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.protocol_error(), "Invalid SETTINGS frame (RFC9113§6.5)"}, <<>>}
    end

    test "deserializes ack frames" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Settings{ack: true, settings: nil}}, <<>>}
    end

    test "rejects ack frames when there is a payload" do
      frame = <<0, 0, 1, 4, 1, 0, 0, 0, 0, 1>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(),
                 "SETTINGS ack frame with non-empty payload (RFC9113§6.5)"}, <<>>}
    end

    test "rejects ack frames when there is stream identifier" do
      frame = <<0, 0, 0, 4, 1, 0, 0, 0, 1>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.protocol_error(), "Invalid SETTINGS frame (RFC9113§6.5)"}, <<>>}
    end
  end

  describe "PUSH_PROMISE frames" do
    test "rejects all frames" do
      frame = <<0, 0, 7, 5, 0, 0, 0, 0, 1, 0, 0, 0, 3, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, 1, "PUSH_PROMISE frame received (RFC9113§8.4)"}, <<>>}
    end
  end

  describe "PING frames" do
    test "deserializes non-ack frames" do
      frame = <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Ping{ack: false, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "deserializes ack frames" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Ping{ack: true, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}}, <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 7, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(),
                 "PING frame with invalid payload size (RFC9113§6.7)"}, <<>>}
    end

    test "rejects frames when there is stream identifier" do
      frame = <<0, 0, 8, 6, 1, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.protocol_error(),
                 "Invalid stream ID in PING frame (RFC9113§6.7)"}, <<>>}
    end
  end

  describe "GOAWAY frames" do
    test "deserializes frames without debug data" do
      frame = <<0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<>>}}, <<>>}
    end

    test "deserializes frames with debug data" do
      frame = <<0, 0, 10, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 3, 4>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<3, 4>>}},
                <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 7, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(),
                 "GOAWAY frame with invalid payload size (RFC9113§6.8)"}, <<>>}
    end

    test "rejects frames when there is stream identifier" do
      frame = <<0, 0, 7, 7, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.protocol_error(),
                 "Invalid stream ID in GOAWAY frame (RFC9113§6.8)"}, <<>>}
    end
  end

  describe "WINDOW_UPDATE frames" do
    test "deserializes frames" do
      frame = <<0, 0, 4, 8, 0, 0, 0, 0, 123, 0, 0, 0, 234>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok, %Frame.WindowUpdate{stream_id: 123, size_increment: 234}}, <<>>}
    end

    test "rejects frames when there is a 0 size increment" do
      frame = <<0, 0, 4, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.flow_control_error(),
                 "Invalid WINDOW_UPDATE size increment (RFC9113§6.9)"}, <<>>}
    end

    test "rejects frames when there is a 0 size increment on a stream" do
      frame = <<0, 0, 4, 8, 0, 0, 0, 0, 123, 0, 0, 0, 0>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.flow_control_error(),
                 "Invalid WINDOW_UPDATE size increment (RFC9113§6.9)"}, <<>>}
    end

    test "rejects frames when there is a malformed payload" do
      frame = <<0, 0, 3, 8, 0, 0, 0, 0, 123, 0, 0, 234>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:error, Errors.frame_size_error(), "Invalid WINDOW_UPDATE frame (RFC9113§6.9)"},
                <<>>}
    end
  end

  describe "CONTINUATION frames" do
    test "deserializes frames" do
      frame = <<0, 0, 3, 9, 0x00, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok,
                 %Frame.Continuation{
                   stream_id: 1,
                   end_headers: false,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end

    test "sets end_headers" do
      frame = <<0, 0, 3, 9, 0x04, 0, 0, 0, 1, 1, 2, 3>>

      assert Frame.deserialize(frame, 16_384) ==
               {{:ok,
                 %Frame.Continuation{
                   stream_id: 1,
                   end_headers: true,
                   fragment: <<1, 2, 3>>
                 }}, <<>>}
    end
  end
end
