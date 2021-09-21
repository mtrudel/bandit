defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.{Errors, Frame, Serializable}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def deserialize(
        <<length::24, type::8, flags::8, _reserved::1, stream_id::31,
          payload::binary-size(length), rest::binary>>,
        max_frame_size
      )
      when length <= max_frame_size do
    type
    |> case do
      0x0 -> Frame.Data.deserialize(flags, stream_id, payload)
      0x1 -> Frame.Headers.deserialize(flags, stream_id, payload)
      0x2 -> Frame.Priority.deserialize(flags, stream_id, payload)
      0x3 -> Frame.RstStream.deserialize(flags, stream_id, payload)
      0x4 -> Frame.Settings.deserialize(flags, stream_id, payload)
      0x5 -> Frame.PushPromise.deserialize(flags, stream_id, payload)
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

  # This is a little more aggressive than necessary. RFC7540§4.2 says we only need
  # to treat frame size violations as connection level errors if the frame in
  # question would affect the connection as a whole, so we could be more surgical
  # here and send stream level errors in some cases. However, we are well within
  # our rights to consider such errors as connection errors
  def deserialize(
        <<length::24, _type::8, _flags::8, _reserved::1, _stream_id::31,
          _payload::binary-size(length), rest::binary>>,
        max_frame_size
      )
      when length > max_frame_size do
    {{:error, {:connection, Errors.frame_size_error(), "Payload size too large (RFC7540§4.2)"}},
     rest}
  end

  def deserialize(<<>>, _max_frame_size) do
    nil
  end

  def deserialize(msg, _max_frame_size) do
    {{:more, msg}, <<>>}
  end

  def serialize(frame, max_frame_size) do
    frame
    |> Serializable.serialize(max_frame_size)
    |> Enum.map(fn {type, flags, stream_id, payload} ->
      [<<IO.iodata_length(payload)::24, type::8, flags::8, 0::1, stream_id::31>>, payload]
    end)
  end
end
