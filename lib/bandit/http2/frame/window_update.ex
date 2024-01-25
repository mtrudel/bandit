defmodule Bandit.HTTP2.Frame.WindowUpdate do
  @moduledoc false

  defstruct stream_id: nil,
            size_increment: nil

  @typedoc "An HTTP/2 WINDOW_UPDATE frame"
  @type t :: %__MODULE__{
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          size_increment: non_neg_integer()
        }

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, _stream_id, <<_reserved::1, 0::31>>) do
    {:error, Bandit.HTTP2.Errors.flow_control_error(),
     "Invalid WINDOW_UPDATE size increment (RFC9113§6.9)"}
  end

  def deserialize(_flags, stream_id, <<_reserved::1, size_increment::31>>) do
    {:ok, %__MODULE__{stream_id: stream_id, size_increment: size_increment}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, Bandit.HTTP2.Errors.frame_size_error(), "Invalid WINDOW_UPDATE frame (RFC9113§6.9)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    def serialize(%Bandit.HTTP2.Frame.WindowUpdate{} = frame, _max_frame_size) do
      [{0x8, 0, frame.stream_id, <<0::1, frame.size_increment::31>>}]
    end
  end
end
