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
        <<fin::1, rsv::3, opcode::4, 1::1, 127::7, length::64, mask::32,
          payload::binary-size(length), rest::binary>>
      ) do
    to_frame(fin, rsv, opcode, mask, payload, rest)
  end

  def deserialize(
        <<fin::1, rsv::3, opcode::4, 1::1, 126::7, length::16, mask::32,
          payload::binary-size(length), rest::binary>>
      ) do
    to_frame(fin, rsv, opcode, mask, payload, rest)
  end

  def deserialize(
        <<fin::1, rsv::3, opcode::4, 1::1, length::7, mask::32, payload::binary-size(length),
          rest::binary>>
      )
      when length <= 125 do
    to_frame(fin, rsv, opcode, mask, payload, rest)
  end

  def deserialize(<<>>) do
    nil
  end

  def deserialize(msg) do
    {{:more, msg}, <<>>}
  end

  defp to_frame(_fin, rsv, _opcode, _mask, _payload, rest) when rsv != 0x0 do
    {{:error, "Received unsupported RSV flags #{rsv}"}, rest}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp to_frame(fin, 0x0, opcode, mask, payload, rest) do
    fin = fin == 0x1
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
      fin = if fin, do: 0x1, else: 0x0
      mask_and_length = payload |> IO.iodata_length() |> mask_and_length()
      [<<fin::1, 0x0::3, opcode::4>>, mask_and_length, payload]
    end)
  end

  defp mask_and_length(length) when length <= 125, do: <<0::1, length::7>>
  defp mask_and_length(length) when length <= 65_535, do: <<0::1, 126::7, length::16>>
  defp mask_and_length(length), do: <<0::1, 127::7, length::64>>

  # Note that masking is an involution, so we don't need a separate unmask function
  def mask(payload, mask, acc \\ <<>>)

  def mask(payload, mask, acc) when is_integer(mask), do: mask(payload, <<mask::32>>, acc)

  def mask(<<h::32, rest::binary>>, <<mask::32>>, acc) do
    mask(rest, mask, acc <> <<Bitwise.bxor(h, mask)::32>>)
  end

  def mask(<<h::8, rest::binary>>, <<current::8, mask::24>>, acc) do
    mask(rest, <<mask::24, current::8>>, acc <> <<Bitwise.bxor(h, current)::8>>)
  end

  def mask(<<>>, _mask, acc), do: acc
end
