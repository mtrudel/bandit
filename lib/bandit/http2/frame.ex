defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.Frame

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def deserialize(
        <<length::24, type::8, flags::8, _reserved::1, stream_id::31,
          payload::binary-size(length), rest::binary>>
      ) do
    type
    |> case do
      0x0 -> Frame.Data.deserialize(flags, stream_id, payload)
      0x1 -> Frame.Headers.deserialize(flags, stream_id, payload)
      0x3 -> Frame.RstStream.deserialize(flags, stream_id, payload)
      0x4 -> Frame.Settings.deserialize(flags, stream_id, payload)
      0x6 -> Frame.Ping.deserialize(flags, stream_id, payload)
      0x7 -> Frame.Goaway.deserialize(flags, stream_id, payload)
      0x8 -> Frame.WindowUpdate.deserialize(flags, stream_id, payload)
      0x9 -> Frame.Continuation.deserialize(flags, stream_id, payload)
      unknown -> Frame.Unknown.deserialize(unknown, flags, stream_id, payload)
    end
    |> case do
      {:ok, frame} -> {{:ok, frame}, rest}
      {:error, reason} -> {{:error, reason}, rest}
    end
  end

  def deserialize(<<>>) do
    nil
  end

  def deserialize(msg) do
    {{:more, msg}, <<>>}
  end

  def serialize(frame) do
    {type, flags, stream_id, payload} = Serializable.serialize(frame)

    [<<byte_size(payload)::24, type::8, flags::8, 0::1, stream_id::31>>, payload]
  end
end
