defmodule WebSocketFrameDeserializationTest do
  use ExUnit.Case, async: true

  import Bandit.PrimitiveOps.WebSocket, only: [ws_mask: 2]

  alias Bandit.PrimitiveOps.WebSocket, as: WebSocketPrimitiveOps
  alias Bandit.WebSocket.Frame

  describe "reserved flag parsing" do
    test "errors on reserved flag 1 being set" do
      frame = <<0x1::1, 0x1::3, 0x1::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Received unsupported RSV flags 1"}
    end

    test "errors on reserved flag 2 being set" do
      frame = <<0x1::1, 0x2::3, 0x1::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Received unsupported RSV flags 2"}
    end
  end

  describe "frame size" do
    test "parses 2 byte frames" do
      payload = String.duplicate("a", 2)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 2::7, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses 10 byte frames" do
      payload = String.duplicate("a", 10)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 10::7, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses frames up to 125 bytes" do
      payload = String.duplicate("a", 125)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 125::7, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses frames 126 bytes long" do
      payload = String.duplicate("a", 126)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 126::7, 126::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses frames 127 bytes long" do
      payload = String.duplicate("a", 127)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 126::7, 127::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses frames 16_000 bytes long" do
      payload = String.duplicate("a", 16_000)
      masked_payload = ws_mask(payload, 1234)

      frame =
        <<0x1::1, 0x0::3, 0x1::4, 1::1, 126::7, 16_000::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "parses frames 1_000_000 bytes long" do
      payload = String.duplicate("a", 1_000_000)
      masked_payload = ws_mask(payload, 1234)

      frame =
        <<0x1::1, 0x0::3, 0x1::4, 1::1, 127::7, 1_000_000::64, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: payload}}
    end

    test "errors on frames over max_frame_size bytes with small frames" do
      payload = String.duplicate("a", 125)
      masked_payload = ws_mask(payload, 1234)

      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 125::7, 1234::32, masked_payload::binary>>

      assert Frame.header_and_payload_length(frame, 124) ==
               {:error, :max_frame_size_exceeded}
    end

    test "errors on frames over max_frame_size bytes with medium frames" do
      payload = String.duplicate("a", 16_000)
      masked_payload = ws_mask(payload, 1234)

      frame =
        <<0x1::1, 0x0::3, 0x1::4, 1::1, 126::7, 16_000::16, 1234::32, masked_payload::binary>>

      assert Frame.header_and_payload_length(frame, 15_999) ==
               {:error, :max_frame_size_exceeded}
    end

    test "errors on frames over max_frame_size bytes with large frames" do
      payload = String.duplicate("a", 1_000_000)
      masked_payload = ws_mask(payload, 1234)

      frame =
        <<0x1::1, 0x0::3, 0x1::4, 1::1, 127::7, 1_000_000::64, 1234::32, masked_payload::binary>>

      assert Frame.header_and_payload_length(frame, 999_999) ==
               {:error, :max_frame_size_exceeded}
    end
  end

  describe "insufficient data" do
    test "returns error" do
      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 125::7, 0::32, 1, 2, 3>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:error, :deserialization_failed}
    end
  end

  describe "extra data" do
    test "returns error" do
      frame = <<0x1::1, 0x0::3, 0x1::4, 1::1, 1::7, 0::32, 1, 2, 3>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:error, :deserialization_failed}
    end
  end

  describe "unknown frame types" do
    test "returns an Unknown frame" do
      frame = <<0x1::1, 0x0::3, 0xF::4, 1::1, 1::7, 0::32, 1>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:error, "unknown opcode #{15}"}
    end
  end

  describe "CONTINUATION frames" do
    test "deserializes frames with fin bit set" do
      frame =
        <<0x1::1, 0x0::3, 0x0::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Continuation{fin: true, data: <<1, 2, 3, 4, 5>>}}
    end

    test "deserializes frames with fin bit clear" do
      frame =
        <<0x0::1, 0x0::3, 0x0::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Continuation{fin: false, data: <<1, 2, 3, 4, 5>>}}
    end

    test "refuses frame with per-message compressed bit set" do
      frame =
        <<0x0::1, 0x4::3, 0x0::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a compressed continuation frame (RFC7692§6.1)"}
    end
  end

  describe "TEXT frames" do
    test "deserializes frames with fin and per-message compressed bits clear" do
      frame =
        <<0x0::1, 0x0::3, 0x1::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: false, compressed: false, data: <<1, 2, 3, 4, 5>>}}
    end

    test "deserializes frames with fin bit set" do
      frame =
        <<0x1::1, 0x0::3, 0x1::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: true, compressed: false, data: <<1, 2, 3, 4, 5>>}}
    end

    test "deserializes frames with per-message compressed bit set" do
      frame =
        <<0x0::1, 0x4::3, 0x1::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Text{fin: false, compressed: true, data: <<1, 2, 3, 4, 5>>}}
    end
  end

  describe "BINARY frames" do
    test "deserializes frames with fin and per-message compressed bits clear" do
      frame =
        <<0x0::1, 0x0::3, 0x2::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Binary{fin: false, compressed: false, data: <<1, 2, 3, 4, 5>>}}
    end

    test "deserializes frames with fin bit set" do
      frame =
        <<0x1::1, 0x0::3, 0x2::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Binary{fin: true, compressed: false, data: <<1, 2, 3, 4, 5>>}}
    end

    test "deserializes frames with per-message compressed bit set" do
      frame =
        <<0x0::1, 0x4::3, 0x2::4, 1::1, 5::7, 0x01020304::32,
          ws_mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Binary{fin: false, compressed: true, data: <<1, 2, 3, 4, 5>>}}
    end
  end

  describe "CONNECTION_CLOSE frames" do
    test "deserializes frames with code and message" do
      payload = String.duplicate("a", 123)

      frame =
        <<0x1::1, 0x0::3, 0x8::4, 1::1, 125::7, 0x01020304::32,
          ws_mask(<<1000::16, payload::binary>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.ConnectionClose{code: 1000, reason: payload}}
    end

    test "deserializes frames with code" do
      frame =
        <<0x1::1, 0x0::3, 0x8::4, 1::1, 2::7, 0x01020304::32,
          ws_mask(<<1000::16>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.ConnectionClose{code: 1000}}
    end

    test "deserializes frames with no payload" do
      frame = <<0x1::1, 0x0::3, 0x8::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:ok, %Frame.ConnectionClose{}}
    end

    test "refuses frame with invalid payload" do
      frame = <<0x1::1, 0x0::3, 0x8::4, 1::1, 1::7, 0x01020304::32, 1>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Invalid connection close payload (RFC6455§5.5)"}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x1::1, 0x0::3, 0x8::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Invalid connection close payload (RFC6455§5.5)"}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::1, 0x0::3, 0x8::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a fragmented connection close frame (RFC6455§5.5)"}
    end

    test "refuses frame with per-message compressed bit set" do
      frame = <<0x1::1, 0x4::3, 0x8::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a compressed connection close frame (RFC7692§6.1)"}
    end
  end

  describe "PING frames" do
    test "deserializes frames with data" do
      payload = String.duplicate("a", 125)

      frame =
        <<0x1::1, 0x0::3, 0x9::4, 1::1, 125::7, 0x01020304::32,
          ws_mask(payload, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Ping{data: payload}}
    end

    test "deserializes frames with no payload" do
      frame = <<0x1::1, 0x0::3, 0x9::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:ok, %Frame.Ping{}}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x1::1, 0x0::3, 0x9::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Invalid ping payload (RFC6455§5.5.2)"}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::1, 0x0::3, 0x9::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a fragmented ping frame (RFC6455§5.5.2)"}
    end

    test "refuses frames with per-message compressed bit set" do
      frame = <<0x1::1, 0x4::3, 0x9::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a compressed ping frame (RFC7692§6.1)"}
    end
  end

  describe "PONG frames" do
    test "deserializes frames with data" do
      payload = String.duplicate("a", 125)

      frame =
        <<0x1::1, 0x0::3, 0xA::4, 1::1, 125::7, 0x01020304::32,
          ws_mask(payload, 0x01020304)::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:ok, %Frame.Pong{data: payload}}
    end

    test "deserializes frames with no payload" do
      frame = <<0x1::1, 0x0::3, 0xA::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) == {:ok, %Frame.Pong{}}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x1::1, 0x0::3, 0xA::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Invalid pong payload (RFC6455§5.5.3)"}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::1, 0x0::3, 0xA::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a fragmented pong frame (RFC6455§5.5.3)"}
    end

    test "refuses frames with per-message compressed bit set" do
      frame = <<0x1::1, 0x4::3, 0xA::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame, WebSocketPrimitiveOps) ==
               {:error, "Cannot have a compressed pong frame (RFC7692§6.1)"}
    end
  end
end
