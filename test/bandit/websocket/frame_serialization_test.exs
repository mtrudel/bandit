defmodule WebSocketFrameSerializationTest do
  use ExUnit.Case, async: true

  alias Bandit.WebSocket.Frame

  describe "frame size" do
    test "serializes frames up to 125 bytes" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames 126 bytes long" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 126)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 126::7, 126::16>>, frame.data]
             ]
    end

    test "serializes frames 127 bytes long" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 127)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 126::7, 127::16>>, frame.data]
             ]
    end

    test "serializes frames 16_000 bytes long" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 16_000)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 126::7, 16_000::16>>, frame.data]
             ]
    end

    test "serializes frames 1_000_000 bytes long" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 1_000_000)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 127::7, 1_000_000::64>>, frame.data]
             ]
    end
  end

  describe "CONTINUATION frames" do
    test "serializes frames with fin bit set" do
      frame = %Frame.Continuation{fin: true, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x0::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames with fin bit clear" do
      frame = %Frame.Continuation{fin: false, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x0::1, 0x0::3, 0x0::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end
  end

  describe "TEXT frames" do
    test "serializes frames with fin bit set" do
      frame = %Frame.Text{fin: true, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x1::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames with fin bit clear" do
      frame = %Frame.Text{fin: false, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x0::1, 0x0::3, 0x1::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end
  end

  describe "BINARY frames" do
    test "serializes frames with fin bit set" do
      frame = %Frame.Binary{fin: true, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x2::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames with fin bit clear" do
      frame = %Frame.Binary{fin: false, data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x0::1, 0x0::3, 0x2::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end
  end

  describe "CONNECTION_CLOSE frames" do
    test "serializes frames with code and message set" do
      frame = %Frame.ConnectionClose{code: 1000, reason: String.duplicate("a", 123)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x8::4>>, <<0::1, 125::7>>, [<<1000::16>>, frame.reason]]
             ]
    end

    test "serializes frames with code set" do
      frame = %Frame.ConnectionClose{code: 1000}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x8::4>>, <<0::1, 2::7>>, [<<1000::16>>, <<>>]]
             ]
    end

    test "serializes frames with no code set" do
      frame = %Frame.ConnectionClose{}

      assert Frame.serialize(frame) == [[<<0x1::1, 0x0::3, 0x8::4>>, <<0::1, 0::7>>, <<>>]]
    end
  end

  describe "PING frames" do
    test "serializes frames with data" do
      frame = %Frame.Ping{data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0x9::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames without data" do
      frame = %Frame.Ping{}

      assert Frame.serialize(frame) == [[<<0x1::1, 0x0::3, 0x9::4>>, <<0::1, 0::7>>, <<>>]]
    end
  end

  describe "PONG frames" do
    test "serializes frames with data" do
      frame = %Frame.Pong{data: String.duplicate("a", 125)}

      assert Frame.serialize(frame) == [
               [<<0x1::1, 0x0::3, 0xA::4>>, <<0::1, 125::7>>, frame.data]
             ]
    end

    test "serializes frames without data" do
      frame = %Frame.Pong{}

      assert Frame.serialize(frame) == [[<<0x1::1, 0x0::3, 0xA::4>>, <<0::1, 0::7>>, <<>>]]
    end
  end
end
