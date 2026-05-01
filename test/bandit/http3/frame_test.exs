defmodule Bandit.HTTP3.FrameTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP3.Frame

  # ---------------------------------------------------------------------------
  # QUIC varint encoding
  # ---------------------------------------------------------------------------

  describe "encode_varint/1" do
    test "encodes 0" do
      assert Frame.encode_varint(0) == <<0x00>>
    end

    test "encodes max 1-byte value (63)" do
      assert Frame.encode_varint(63) == <<0b00_111111>>
    end

    test "encodes 64 in 2 bytes" do
      # 2-byte prefix = 0b01, value = 64 as 14 bits
      assert Frame.encode_varint(64) == <<0b01_000000, 64>>
    end

    test "encodes max 2-byte value (16383)" do
      assert Frame.encode_varint(16_383) == <<0b01_111111, 0xFF>>
    end

    test "encodes 16384 in 4 bytes" do
      assert Frame.encode_varint(16_384) == <<0b10_000000, 0, 64, 0>>
    end

    test "encodes max 4-byte value (1_073_741_823)" do
      assert Frame.encode_varint(1_073_741_823) == <<0b10_111111, 0xFF, 0xFF, 0xFF>>
    end

    test "encodes 8-byte value" do
      # 1_073_741_824 requires 8 bytes
      <<prefix::2, v::62>> = Frame.encode_varint(1_073_741_824)
      assert prefix == 3
      assert v == 1_073_741_824
    end
  end

  describe "decode_varint/1" do
    test "decodes 1-byte value" do
      assert Frame.decode_varint(<<0x2A>>) == {:ok, 42, <<>>}
    end

    test "decodes 2-byte value" do
      encoded = Frame.encode_varint(1000)
      assert Frame.decode_varint(encoded) == {:ok, 1000, <<>>}
    end

    test "decodes 4-byte value" do
      encoded = Frame.encode_varint(100_000)
      assert Frame.decode_varint(encoded) == {:ok, 100_000, <<>>}
    end

    test "decodes 8-byte value" do
      encoded = Frame.encode_varint(1_073_741_824)
      assert Frame.decode_varint(encoded) == {:ok, 1_073_741_824, <<>>}
    end

    test "returns :more on empty binary" do
      assert Frame.decode_varint(<<>>) == :more
    end

    test "returns :more when truncated 2-byte value" do
      # 2-byte prefix set but only 1 byte provided
      assert Frame.decode_varint(<<0b01_000000>>) == :more
    end

    test "leaves trailing bytes in rest" do
      data = Frame.encode_varint(5) <> <<0xAB, 0xCD>>
      assert Frame.decode_varint(data) == {:ok, 5, <<0xAB, 0xCD>>}
    end

    test "encode/decode round-trips" do
      for v <- [0, 1, 63, 64, 100, 16_383, 16_384, 1_000_000, 1_073_741_823] do
        assert {:ok, ^v, <<>>} = Frame.decode_varint(Frame.encode_varint(v))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Frame serialization
  # ---------------------------------------------------------------------------

  describe "serialize/1 DATA" do
    test "empty data" do
      # type=0x00 (1 byte), length=0 (1 byte), payload=<<>>
      assert Frame.serialize({:data, <<>>}) |> IO.iodata_to_binary() == <<0x00, 0x00>>
    end

    test "short body" do
      payload = "hello"
      result = Frame.serialize({:data, payload}) |> IO.iodata_to_binary()
      assert result == <<0x00, byte_size(payload)>> <> payload
    end

    test "body encoded as iodata" do
      # iolist input must be flattened
      result = Frame.serialize({:data, ["hel", "lo"]}) |> IO.iodata_to_binary()
      assert result == <<0x00, 5>> <> "hello"
    end
  end

  describe "serialize/1 HEADERS" do
    test "non-empty header block" do
      block = <<0x01, 0x02, 0x03>>
      result = Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
      assert result == <<0x01, byte_size(block)>> <> block
    end
  end

  describe "serialize/1 SETTINGS" do
    test "empty settings" do
      result = Frame.serialize({:settings, []}) |> IO.iodata_to_binary()
      # type=0x04, length=0
      assert result == <<0x04, 0x00>>
    end

    test "single setting" do
      result = Frame.serialize({:settings, [{0x01, 0}]}) |> IO.iodata_to_binary()
      # type=0x04, length=2, id=0x01, val=0x00
      assert result == <<0x04, 0x02, 0x01, 0x00>>
    end

    test "multiple settings" do
      settings = [{0x01, 0}, {0x06, 65_536}]
      result = Frame.serialize({:settings, settings}) |> IO.iodata_to_binary()
      {:ok, {:settings, decoded}, <<>>} = Frame.deserialize(result)
      assert decoded == settings
    end
  end

  describe "serialize/1 GOAWAY" do
    test "stream_id 0" do
      result = Frame.serialize({:goaway, 0}) |> IO.iodata_to_binary()
      # type=0x07, length=1 (varint 0), payload=0
      assert result == <<0x07, 0x01, 0x00>>
    end

    test "larger stream_id round-trips" do
      result = Frame.serialize({:goaway, 100}) |> IO.iodata_to_binary()
      assert {:ok, {:goaway, 100}, <<>>} = Frame.deserialize(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Frame deserialization
  # ---------------------------------------------------------------------------

  describe "deserialize/1" do
    test "returns :more for empty binary" do
      assert {:more, <<>>} = Frame.deserialize(<<>>)
    end

    test "returns :more when only type varint present" do
      assert {:more, _} = Frame.deserialize(<<0x00>>)
    end

    test "returns :more when payload is incomplete" do
      # type=DATA, length=5, but only 3 payload bytes
      assert {:more, _} = Frame.deserialize(<<0x00, 0x05, "hel">>)
    end

    test "deserializes DATA frame" do
      encoded = Frame.serialize({:data, "hello"}) |> IO.iodata_to_binary()
      assert {:ok, {:data, "hello"}, <<>>} = Frame.deserialize(encoded)
    end

    test "deserializes HEADERS frame" do
      block = <<0xDE, 0xAD, 0xBE, 0xEF>>
      encoded = Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
      assert {:ok, {:headers, ^block}, <<>>} = Frame.deserialize(encoded)
    end

    test "deserializes SETTINGS frame" do
      settings = [{0x01, 0}, {0x06, 65_536}]
      encoded = Frame.serialize({:settings, settings}) |> IO.iodata_to_binary()
      assert {:ok, {:settings, ^settings}, <<>>} = Frame.deserialize(encoded)
    end

    test "deserializes GOAWAY frame" do
      encoded = Frame.serialize({:goaway, 8}) |> IO.iodata_to_binary()
      assert {:ok, {:goaway, 8}, <<>>} = Frame.deserialize(encoded)
    end

    test "decodes unknown frame type as :unknown" do
      # type=0xFF, length=2, payload=<<0xAB, 0xCD>>
      data = <<Frame.encode_varint(0xFF)::binary, 0x02, 0xAB, 0xCD>>
      assert {:ok, {:unknown, 0xFF, <<0xAB, 0xCD>>}, <<>>} = Frame.deserialize(data)
    end

    test "leaves trailing bytes in rest" do
      frame = Frame.serialize({:data, "hi"}) |> IO.iodata_to_binary()
      trailer = <<0xCA, 0xFE>>
      assert {:ok, {:data, "hi"}, ^trailer} = Frame.deserialize(frame <> trailer)
    end

    test "decodes concatenated frames sequentially" do
      f1 = Frame.serialize({:data, "A"}) |> IO.iodata_to_binary()
      f2 = Frame.serialize({:data, "B"}) |> IO.iodata_to_binary()
      both = f1 <> f2

      {:ok, {:data, "A"}, rest} = Frame.deserialize(both)
      assert {:ok, {:data, "B"}, <<>>} = Frame.deserialize(rest)
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip properties
  # ---------------------------------------------------------------------------

  describe "serialize → deserialize round-trips" do
    test "DATA frame" do
      assert {:ok, {:data, "body"}, <<>>} =
               Frame.serialize({:data, "body"})
               |> IO.iodata_to_binary()
               |> Frame.deserialize()
    end

    test "HEADERS frame" do
      block = :crypto.strong_rand_bytes(20)

      assert {:ok, {:headers, ^block}, <<>>} =
               Frame.serialize({:headers, block})
               |> IO.iodata_to_binary()
               |> Frame.deserialize()
    end

    test "SETTINGS frame" do
      settings = [{1, 0}, {6, 65_536}]

      assert {:ok, {:settings, ^settings}, <<>>} =
               Frame.serialize({:settings, settings})
               |> IO.iodata_to_binary()
               |> Frame.deserialize()
    end

    test "GOAWAY frame" do
      assert {:ok, {:goaway, 42}, <<>>} =
               Frame.serialize({:goaway, 42})
               |> IO.iodata_to_binary()
               |> Frame.deserialize()
    end

    test "DATA frame with large payload (2-byte length varint)" do
      # 64 bytes triggers 2-byte length varint
      payload = :crypto.strong_rand_bytes(64)

      assert {:ok, {:data, ^payload}, <<>>} =
               Frame.serialize({:data, payload})
               |> IO.iodata_to_binary()
               |> Frame.deserialize()
    end
  end
end
