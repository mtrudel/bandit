defmodule Bandit.HTTP2.Frame.WindowUpdate do
  @moduledoc false

  alias Bandit.HTTP2.Errors

  defstruct stream_id: nil,
            size_increment: nil

  def deserialize(_flags, _stream_id, <<_reserved::1, 0::31>>) do
    {:error,
     {:connection, Errors.flow_control_error(),
      "Invalid WINDOW_UPDATE size increment (RFC7540§6.9)"}}
  end

  def deserialize(_flags, stream_id, <<_reserved::1, size_increment::31>>) do
    {:ok, %__MODULE__{stream_id: stream_id, size_increment: size_increment}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Errors.frame_size_error(), "Invalid WINDOW_UPDATE frame (RFC7540§6.9)"}}
  end

  defimpl Bandit.HTTP2.Serializable do
    alias Bandit.HTTP2.Frame.WindowUpdate

    def serialize(%WindowUpdate{} = frame, _max_frame_size) do
      [{0x8, 0, frame.stream_id, <<0::1, frame.size_increment::31>>}]
    end
  end
end
