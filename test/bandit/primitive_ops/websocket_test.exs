defmodule Bandit.PrimitiveOps.WebSocketTest do
  use ExUnit.Case, async: true

  alias Bandit.PrimitiveOps.WebSocket

  test "matches the RFC 6455 masking example" do
    assert WebSocket.ws_mask("Hello", 0x37FA213D) == <<0x7F, 0x9F, 0x4D, 0x51, 0x58>>
  end

  test "masks payloads across optimized chunk boundaries" do
    for mask_integer <- [0, 1, 0x01020304, 0x80000000, 0xFFFFFFFF], size <- 0..65 do
      mask = <<mask_integer::32>>
      payload = :binary.copy(<<0x01>>, size)

      expected =
        payload
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
        |> :binary.list_to_bin()

      assert WebSocket.ws_mask(payload, mask_integer) == expected
      assert WebSocket.ws_mask(expected, mask_integer) == payload
    end
  end
end
