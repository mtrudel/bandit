defmodule WebSocketExtractorTest do
  use ExUnit.Case, async: true

  alias Bandit.Extractor
  alias Bandit.WebSocket.Frame

  defp new_extractor,
    do: Extractor.new(Frame, Bandit.PrimitiveOps.WebSocket, max_frame_size: 8_000_000)

  test "a frame payload that arrives as many 1 byte packets does not hold memory far above its size" do
    # Each received packet was kept as a separate binary in the payload buffer, which cost
    # about 40 bytes of memory per byte of payload
    length = 200_000
    payload = for i <- 1..length, into: <<>>, do: <<rem(i, 256)>>

    extractor =
      new_extractor()
      |> Extractor.push_data(<<0x82, 1::1, 127::7, length::64, 0::32>>)

    {extractor, :more} = Extractor.pop_frame(extractor)

    extractor =
      for <<byte::binary-size(1) <- payload>>, reduce: extractor do
        extractor -> Extractor.push_data(extractor, byte)
      end

    # Before the fix this was ~1.4 M words (~11 MB) for 200 KB of payload
    assert :erts_debug.size(extractor) < 20_000

    assert {_extractor, {:ok, %Frame.Binary{fin: true, data: ^payload}}} =
             Extractor.pop_frame(extractor)
  end

  test "many small frames in one packet are not copied one time for each frame" do
    # Regression guard: if each pop copies the rest of the packet, a packet of N small frames
    # costs O(N * packet size)
    frames = 10_000
    packet = :binary.copy(<<0x81, 1::1, 1::7, 0::32, "A">>, frames)
    extractor = new_extractor() |> Extractor.push_data(packet)

    extractor =
      Enum.reduce(1..frames, extractor, fn _, extractor ->
        assert {extractor, {:ok, %Frame.Text{data: "A"}}} = Extractor.pop_frame(extractor)

        # What is left must still refer to the received packet, not to a copy of it. The VM
        # keeps binaries of 64 bytes or less on the process heap, so check only larger ones
        if byte_size(extractor.header) > 64,
          do: assert(:binary.referenced_byte_size(extractor.header) == byte_size(packet))

        extractor
      end)

    assert {_extractor, :more} = Extractor.pop_frame(extractor)
  end

  test "bytes after the frame are kept when the payload arrives as many packets" do
    extractor =
      new_extractor()
      |> Extractor.push_data(<<0x82, 1::1, 126::7, 3000::16, 0::32>>)

    {extractor, :more} = Extractor.pop_frame(extractor)

    extractor =
      for _ <- 1..2999, reduce: extractor do
        extractor -> Extractor.push_data(extractor, "A")
      end

    # The last packet holds the end of the first frame and all of a second frame
    extractor = Extractor.push_data(extractor, <<"A", 0x81, 1::1, 2::7, 0::32, "OK">>)

    assert {extractor, {:ok, %Frame.Binary{data: data}}} = Extractor.pop_frame(extractor)
    assert data == String.duplicate("A", 3000)
    assert {_extractor, {:ok, %Frame.Text{data: "OK"}}} = Extractor.pop_frame(extractor)
  end
end
