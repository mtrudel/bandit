defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.Frame

  require Logger

  def deserialize(
        <<length::24, type::8, flags::8, _reserved::1, stream_id::31,
          payload::binary-size(length), rest::binary>>
      ) do
    type
    |> case do
      0x0 -> Frame.Data.deserialize(flags, stream_id, payload)
      0x1 -> Frame.Headers.deserialize(flags, stream_id, payload)
      0x4 -> Frame.Settings.deserialize(flags, stream_id, payload)
      0x6 -> Frame.Ping.deserialize(flags, stream_id, payload)
      0x7 -> Frame.Goaway.deserialize(flags, stream_id, payload)
      unknown -> handle_unknown_frame(unknown, flags, stream_id, payload)
    end
    |> case do
      {:ok, frame} -> {{:ok, frame}, rest}
      {:error, stream_id, code, reason} -> {{:error, stream_id, code, reason}, rest}
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

  defp handle_unknown_frame(type, flags, stream_id, payload) do
    Logger.warn("Unknown frame (t: #{type} f: #{flags} s: #{stream_id} p: #{inspect(payload)})")

    {:ok, nil}
  end
end
