defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  @typedoc "Indicates a frame type"
  @type frame_type :: non_neg_integer()

  @typedoc "The flags passed along with a frame"
  @type flags :: byte()

  @typedoc "A valid HTTP/2 frame"
  @type frame ::
          Frame.Data.t()
          | Frame.Headers.t()
          | Frame.Priority.t()
          | Frame.RstStream.t()
          | Frame.Settings.t()
          | Frame.Ping.t()
          | Frame.Goaway.t()
          | Frame.WindowUpdate.t()
          | Frame.Continuation.t()
          | Frame.Unknown.t()

  @spec deserialize(binary(), non_neg_integer()) ::
          {{:ok, frame()}, iodata()} | {{:error, Connection.error()}, iodata()} | nil
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

  # This is a little more aggressive than necessary. RFC9113§4.2 says we only need
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
    {{:error, {:connection, Errors.frame_size_error(), "Payload size too large (RFC9113§4.2)"}},
     rest}
  end

  # nil is used to indicate for Stream.unfold/2 that the frame deserialization is finished
  def deserialize(<<>>, _max_frame_size) do
    nil
  end

  def deserialize(msg, _max_frame_size) do
    {{:more, msg}, <<>>}
  end

  defmodule Flags do
    @moduledoc false

    import Bitwise

    defguard set?(flags, bit) when band(flags, bsl(1, bit)) != 0
    defguard clear?(flags, bit) when band(flags, bsl(1, bit)) == 0

    @spec set([0..255]) :: 0..255
    def set([]), do: 0x0
    def set([bit | rest]), do: bor(bsl(1, bit), set(rest))
  end

  defprotocol Serializable do
    @moduledoc false

    @spec serialize(any(), non_neg_integer()) :: [
            {Frame.frame_type(), Frame.flags(), Stream.stream_id(), iodata()}
          ]
    def serialize(frame, max_frame_size)
  end

  @spec serialize(frame(), non_neg_integer()) :: iolist()
  def serialize(frame, max_frame_size) do
    frame
    |> Serializable.serialize(max_frame_size)
    |> Enum.map(fn {type, flags, stream_id, payload} ->
      [<<IO.iodata_length(payload)::24, type::8, flags::8, 0::1, stream_id::31>>, payload]
    end)
  end
end
