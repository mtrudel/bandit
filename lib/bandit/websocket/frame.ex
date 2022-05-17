defmodule Bandit.WebSocket.Frame do
  @moduledoc false

  alias Bandit.WebSocket.Frame

  @typedoc "Indicates an opcode"
  @type opcode :: non_neg_integer()

  @typedoc "A valid WebSocket frame"
  @type frame ::
          Frame.Continuation.t()
          | Frame.Text.t()
          | Frame.Binary.t()
          | Frame.ConnectionClose.t()
          | Frame.Ping.t()
          | Frame.Pong.t()

  @spec deserialize(binary()) :: {{:ok, frame()}, iodata()} | {{:error, term()}, iodata()}
  def deserialize(
        <<flags::4, opcode::4, 1::1, 127::7, length::64, mask::32, payload::binary-size(length),
          rest::binary>>
      ) do
    to_frame(flags, opcode, mask, payload, rest)
  end

  def deserialize(
        <<flags::4, opcode::4, 1::1, 126::7, length::16, mask::32, payload::binary-size(length),
          rest::binary>>
      ) do
    to_frame(flags, opcode, mask, payload, rest)
  end

  def deserialize(
        <<flags::4, opcode::4, 1::1, length::7, mask::32, payload::binary-size(length),
          rest::binary>>
      ) do
    to_frame(flags, opcode, mask, payload, rest)
  end

  def deserialize(msg) do
    {{:more, msg}, <<>>}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp to_frame(flags, opcode, mask, payload, rest) do
    fin = Bitwise.band(flags, 0x8) != 0x0
    unmasked_payload = mask(payload, mask)

    opcode
    |> case do
      0x0 -> Frame.Continuation.deserialize(fin, unmasked_payload)
      0x1 -> Frame.Text.deserialize(fin, unmasked_payload)
      0x2 -> Frame.Binary.deserialize(fin, unmasked_payload)
      0x8 -> Frame.ConnectionClose.deserialize(fin, unmasked_payload)
      0x9 -> Frame.Ping.deserialize(fin, unmasked_payload)
      0xA -> Frame.Pong.deserialize(fin, unmasked_payload)
      unknown -> {:error, "unknown opcode #{unknown}"}
    end
    |> case do
      {:ok, frame} -> {{:ok, frame}, rest}
      {:error, reason} -> {{:error, reason}, rest}
    end
  end

  defprotocol Serializable do
    @moduledoc false

    @spec serialize(any()) :: [{Frame.opcode(), boolean(), iodata()}]
    def serialize(frame)
  end

  @spec serialize(frame()) :: iodata()
  def serialize(frame) do
    frame
    |> Serializable.serialize()
    |> Enum.map(fn {opcode, fin, payload} ->
      flags = if fin, do: 0x8, else: 0x0
      mask_and_length = payload |> IO.iodata_length() |> mask_and_length()
      [<<flags::4, opcode::4>>, mask_and_length, payload]
    end)
  end

  defp mask_and_length(length) when length <= 125, do: <<0::1, length::7>>
  defp mask_and_length(length) when length <= 65_535, do: <<0::1, 126::7, length::16>>
  defp mask_and_length(length), do: <<0::1, 127::7, length::64>>

  # Note that masking is an involution, so we don't need a separate unmask function
  def mask(payload, mask) do
    maskstream = mask |> :binary.encode_unsigned() |> :binary.bin_to_list() |> Stream.cycle()

    payload
    |> :binary.bin_to_list()
    |> Enum.zip(maskstream)
    |> Enum.map(fn {x, y} -> Bitwise.bxor(x, y) end)
    |> :binary.list_to_bin()
  end
end
