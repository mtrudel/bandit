defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.Frame

  require Logger

  def deserialize(
        <<length::24, type::8, flags::binary-size(1), _reserved::1, stream_id::31,
          payload::binary-size(length), rest::binary>>
      ) do
    type
    |> case do
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

    <<byte_size(payload)::24, type::8, flags::binary-size(1), 0::1, stream_id::31,
      payload::binary>>
  end

  defp handle_unknown_frame(type, flags, stream_id, payload) do
    "Unknown frame (t: #{type} f: #{inspect(flags)} s: #{stream_id} p: #{inspect(payload)})"
    |> Logger.warn()

    {:ok, nil}
  end
end
