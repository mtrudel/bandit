defmodule WebSocketFrameDeserializationTest do
  use ExUnit.Case, async: true

  import Bandit.WebSocket.Frame, only: [mask: 2]

  alias Bandit.WebSocket.Frame

  describe "frame size" do
    test "parses frames up to 125 bytes" do
      payload = String.duplicate("a", 125)
      masked_payload = Bandit.WebSocket.Frame.mask(payload, 1234)

      frame = <<0x8::4, 0x1::4, 1::1, 125::7, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: payload}}, <<>>}
    end

    test "parses frames 126 bytes long" do
      payload = String.duplicate("a", 126)
      masked_payload = Bandit.WebSocket.Frame.mask(payload, 1234)

      frame = <<0x8::4, 0x1::4, 1::1, 126::7, 126::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: payload}}, <<>>}
    end

    test "parses frames 127 bytes long" do
      payload = String.duplicate("a", 127)
      masked_payload = Bandit.WebSocket.Frame.mask(payload, 1234)

      frame = <<0x8::4, 0x1::4, 1::1, 126::7, 127::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: payload}}, <<>>}
    end

    test "parses frames 16_000 bytes long" do
      payload = String.duplicate("a", 16_000)
      masked_payload = Bandit.WebSocket.Frame.mask(payload, 1234)

      frame = <<0x8::4, 0x1::4, 1::1, 126::7, 16_000::16, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: payload}}, <<>>}
    end

    test "parses frames 1_000_000 bytes long" do
      payload = String.duplicate("a", 1_000_000)
      masked_payload = Bandit.WebSocket.Frame.mask(payload, 1234)

      frame = <<0x8::4, 0x1::4, 1::1, 127::7, 1_000_000::64, 1234::32, masked_payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: payload}}, <<>>}
    end
  end

  describe "insufficient data" do
    test "asks for more" do
      frame = <<0x8::4, 0x1::4, 1::1, 125::7, 0::32, 1, 2, 3>>

      assert Frame.deserialize(frame) == {{:more, frame}, <<>>}
    end
  end

  describe "extra data" do
    test "returns extra data" do
      frame = <<0x8::4, 0x1::4, 1::1, 1::7, 0::32, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: <<1>>}}, <<2, 3>>}
    end
  end

  describe "unknown frame types" do
    test "returns an Unknown frame" do
      frame = <<0x8::4, 0xF::4, 1::1, 1::7, 0::32, 1, 2, 3>>

      assert Frame.deserialize(frame) ==
               {{:error, "unknown opcode #{15}"}, <<2, 3>>}
    end
  end

  describe "CONTINUATION frames" do
    test "deserializes frames with fin bit set" do
      frame =
        <<0x8::4, 0x0::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Continuation{fin: true, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end

    test "deserializes frames with fin bit clear" do
      frame =
        <<0x0::4, 0x0::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Continuation{fin: false, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end
  end

  describe "TEXT frames" do
    test "deserializes frames with fin bit set" do
      frame =
        <<0x8::4, 0x1::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: true, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end

    test "deserializes frames with fin bit clear" do
      frame =
        <<0x0::4, 0x1::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Text{fin: false, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end

    # TODO - test for UTF-8 handling (once we determine what to do about fragments in light of RFC6455§5.6
  end

  describe "BINARY frames" do
    test "deserializes frames with fin bit set" do
      frame =
        <<0x8::4, 0x2::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Binary{fin: true, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end

    test "deserializes frames with fin bit clear" do
      frame =
        <<0x0::4, 0x2::4, 1::1, 5::7, 0x01020304::32,
          mask(<<1, 2, 3, 4, 5>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Binary{fin: false, data: <<1, 2, 3, 4, 5>>}}, <<>>}
    end
  end

  describe "CONNECTION_CLOSE frames" do
    test "deserializes frames with code and message" do
      payload = String.duplicate("a", 123)

      frame =
        <<0x8::4, 0x8::4, 1::1, 125::7, 0x01020304::32,
          mask(<<1000::16, payload::binary>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.ConnectionClose{code: 1000, reason: payload}}, <<>>}
    end

    test "deserializes frames with code" do
      frame =
        <<0x8::4, 0x8::4, 1::1, 2::7, 0x01020304::32, mask(<<1000::16>>, 0x01020304)::binary>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.ConnectionClose{code: 1000}}, <<>>}
    end

    test "deserializes frames with no payload" do
      frame = <<0x8::4, 0x8::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.ConnectionClose{}}, <<>>}
    end

    test "refuses frame with invalid payload" do
      frame = <<0x8::4, 0x8::4, 1::1, 1::7, 0x01020304::32, 1>>

      assert Frame.deserialize(frame) ==
               {{:error, "Invalid connection close payload (RFC6455§5.5)"}, <<>>}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x8::4, 0x8::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:error, "Invalid connection close payload (RFC6455§5.5)"}, <<>>}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::4, 0x8::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) ==
               {{:error, "Cannot have a fragmented connection close frame (RFC6455§5.5)"}, <<>>}
    end
  end

  describe "PING frames" do
    test "deserializes frames with data" do
      payload = String.duplicate("a", 125)

      frame = <<0x8::4, 0x9::4, 1::1, 125::7, 0x01020304::32, mask(payload, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Ping{data: payload}}, <<>>}
    end

    test "deserializes frames with no payload" do
      frame = <<0x8::4, 0x9::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Ping{}}, <<>>}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x8::4, 0x9::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:error, "Invalid ping payload (RFC6455§5.5.2)"}, <<>>}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::4, 0x9::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) ==
               {{:error, "Cannot have a fragmented ping frame (RFC6455§5.5.2)"}, <<>>}
    end
  end

  describe "PONG frames" do
    test "deserializes frames with data" do
      payload = String.duplicate("a", 125)

      frame = <<0x8::4, 0xA::4, 1::1, 125::7, 0x01020304::32, mask(payload, 0x01020304)::binary>>

      assert Frame.deserialize(frame) ==
               {{:ok, %Frame.Pong{data: payload}}, <<>>}
    end

    test "deserializes frames with no payload" do
      frame = <<0x8::4, 0xA::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) == {{:ok, %Frame.Pong{}}, <<>>}
    end

    test "refuses frame with overly large payload" do
      payload = String.duplicate("a", 126)
      frame = <<0x8::4, 0xA::4, 1::1, 126::7, 126::16, 0x01020304::32, payload::binary>>

      assert Frame.deserialize(frame) ==
               {{:error, "Invalid pong payload (RFC6455§5.5.3)"}, <<>>}
    end

    test "refuses frames with fin bit clear" do
      frame = <<0x0::4, 0xA::4, 1::1, 0::7, 0x01020304::32>>

      assert Frame.deserialize(frame) ==
               {{:error, "Cannot have a fragmented pong frame (RFC6455§5.5.3)"}, <<>>}
    end
  end
end
