defmodule HTTP2FrameSerializationTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.{Frame, Settings}

  describe "DATA frames" do
    test "serializes frames" do
      frame = %Frame.Data{
        stream_id: 123,
        end_stream: false,
        data: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 3, 0, 0, 0, 0, 0, 123>>, <<1, 2, 3>>]]
    end

    test "serializes frames into multiple size-respecting frames" do
      frame = %Frame.Data{
        stream_id: 123,
        end_stream: false,
        data: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 2) == [
               [<<0, 0, 2, 0, 0, 0, 0, 0, 123>>, <<1, 2>>],
               [<<0, 0, 1, 0, 0, 0, 0, 0, 123>>, <<3>>]
             ]
    end

    test "serializes frames with end_stream set" do
      frame = %Frame.Data{
        stream_id: 123,
        end_stream: true,
        data: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 3, 0, 1, 0, 0, 0, 123>>, <<1, 2, 3>>]]
    end

    test "serializes frames with end_stream set into multiple size-respecting frames" do
      frame = %Frame.Data{
        stream_id: 123,
        end_stream: true,
        data: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 2) == [
               [<<0, 0, 2, 0, 0, 0, 0, 0, 123>>, <<1, 2>>],
               [<<0, 0, 1, 0, 1, 0, 0, 0, 123>>, <<3>>]
             ]
    end
  end

  describe "HEADERS frames" do
    test "serializes frames" do
      frame = %Frame.Headers{
        stream_id: 123,
        end_stream: false,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 3, 1, 4, 0, 0, 0, 123>>, <<1, 2, 3>>]]
    end

    test "serializes frames into multiple size-respecting frames" do
      frame = %Frame.Headers{
        stream_id: 123,
        end_stream: false,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 2) == [
               [<<0, 0, 2, 1, 0, 0, 0, 0, 123>>, <<1, 2>>],
               [<<0, 0, 1, 9, 4, 0, 0, 0, 123>>, <<3>>]
             ]
    end

    test "serializes frames with end_stream set" do
      frame = %Frame.Headers{
        stream_id: 123,
        end_stream: true,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 3, 1, 5, 0, 0, 0, 123>>, <<1, 2, 3>>]]
    end

    test "serializes frames with end_stream set into multiple size-respecting frames" do
      frame = %Frame.Headers{
        stream_id: 123,
        end_stream: true,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 2) == [
               [<<0, 0, 2, 1, 1, 0, 0, 0, 123>>, <<1, 2>>],
               [<<0, 0, 1, 9, 4, 0, 0, 0, 123>>, <<3>>]
             ]
    end
  end

  describe "PRIORITY frames" do
    test "serializes frames" do
      frame = %Frame.Priority{
        stream_id: 123,
        dependent_stream_id: 456,
        weight: 78
      }

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 5, 2, 0, 0, 0, 0, 123>>, <<0::1, 456::31, 78::8>>]
             ]
    end
  end

  describe "RST_STREAM frames" do
    test "serializes frames" do
      frame = %Frame.RstStream{
        stream_id: 123,
        error_code: 456
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 4, 3, 0, 0, 0, 0, 123>>, <<456::32>>]]
    end
  end

  describe "SETTINGS frames" do
    test "serializes non-ack frames when there are no non-default settings" do
      frame = %Frame.Settings{ack: false, settings: %Settings{}}

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 0, 4, 0, 0, 0, 0, 0>>, [<<>>, <<>>, <<>>, <<>>, <<>>, <<>>]]
             ]
    end

    test "serializes non-ack frames when there are non-default settings" do
      frame = %Frame.Settings{
        ack: false,
        settings: %Settings{
          header_table_size: 1000,
          enable_push: false,
          max_concurrent_streams: 2000,
          initial_window_size: 3000,
          max_frame_size: 40_000,
          max_header_list_size: 5000
        }
      }

      assert Frame.serialize(frame, 16_384) ==
               [
                 [
                   <<0, 0, 36, 4, 0, 0, 0, 0, 0>>,
                   [
                     <<2::16, 0::32>>,
                     <<1::16, 1000::32>>,
                     <<4::16, 3000::32>>,
                     <<3::16, 2000::32>>,
                     <<5::16, 40_000::32>>,
                     <<6::16, 5000::32>>
                   ]
                 ]
               ]
    end

    test "serializes ack frames" do
      frame = %Frame.Settings{ack: true, settings: %{}}

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 0, 4, 1, 0, 0, 0, 0>>, <<>>]]
    end
  end

  describe "PUSH_PROMISE frames" do
    test "serializes frames" do
      frame = %Frame.PushPromise{
        stream_id: 123,
        promised_stream_id: 234,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 7, 5, 4, 0, 0, 0, 123>>, <<0, 0, 0, 234, 1, 2, 3>>]
             ]
    end

    test "serializes frames into multiple size-respecting frames" do
      frame = %Frame.PushPromise{
        stream_id: 123,
        promised_stream_id: 234,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 6) == [
               [<<0, 0, 6, 5, 0, 0, 0, 0, 123>>, <<0, 0, 0, 234, 1, 2>>],
               [<<0, 0, 1, 9, 4, 0, 0, 0, 123>>, <<3>>]
             ]
    end
  end

  describe "PING frames" do
    test "serializes non-ack frames" do
      frame = %Frame.Ping{ack: false, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 8, 6, 0, 0, 0, 0, 0>>, <<1, 2, 3, 4, 5, 6, 7, 8>>]
             ]
    end

    test "serializes ack frames" do
      frame = %Frame.Ping{ack: true, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 8, 6, 1, 0, 0, 0, 0>>, <<1, 2, 3, 4, 5, 6, 7, 8>>]
             ]
    end
  end

  describe "GOAWAY frames" do
    test "serializes frames without debug data" do
      frame = %Frame.Goaway{last_stream_id: 1, error_code: 2}

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 8, 7, 0, 0, 0, 0, 0>>, <<0, 0, 0, 1, 0, 0, 0, 2>>]
             ]
    end

    test "serializes frames with debug data" do
      frame = %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<3, 4>>}

      assert Frame.serialize(frame, 16_384) ==
               [[<<0, 0, 10, 7, 0, 0, 0, 0, 0>>, <<0, 0, 0, 1, 0, 0, 0, 2, 3, 4>>]]
    end
  end

  describe "WINDOW_UPDATE frames" do
    test "serializes frames" do
      frame = %Frame.WindowUpdate{
        stream_id: 123,
        size_increment: 234
      }

      assert Frame.serialize(frame, 16_384) == [
               [<<0, 0, 4, 8, 0, 0, 0, 0, 123>>, <<0, 0, 0, 234>>]
             ]
    end
  end

  describe "CONTINUATION frames" do
    test "serializes frames" do
      frame = %Frame.Continuation{
        stream_id: 123,
        fragment: <<1, 2, 3>>
      }

      assert Frame.serialize(frame, 16_384) == [[<<0, 0, 3, 9, 4, 0, 0, 0, 123>>, <<1, 2, 3>>]]
    end
  end
end
