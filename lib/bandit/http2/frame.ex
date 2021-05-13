defmodule Bandit.HTTP2.Frame do
  @moduledoc false

  alias Bandit.HTTP2.Frame

  require Logger

  def deserialize(
        <<length::24, type::8, flags::binary-size(1), _reserved::1, stream::31,
          payload::binary-size(length), rest::binary>>
      ) do
    type
    |> case do
      0x4 -> Frame.Settings.deserialize(flags, stream, payload)
      0x6 -> Frame.Ping.deserialize(flags, stream, payload)
      unknown -> handle_unknown_frame(unknown, flags, stream, payload)
    end
    |> case do
      {:ok, frame} -> {{:ok, frame}, rest}
      {:error, stream, code, reason} -> {{:error, stream, code, reason}, rest}
    end
  end

  def deserialize(<<>>) do
    nil
  end

  def deserialize(msg) do
    {{:more, msg}, <<>>}
  end

  def serialize(frame) do
    {type, flags, stream, payload} = Serializable.serialize(frame)
    <<byte_size(payload)::24, type::8, flags::binary-size(1), 0::1, stream::31, payload::binary>>
  end

  defp handle_unknown_frame(type, flags, stream, payload) do
    "Unknown frame (t: #{type} f: #{inspect(flags)} s: #{stream} p: #{inspect(payload)})"
    |> Logger.warn()

    {:ok, nil}
  end
end
