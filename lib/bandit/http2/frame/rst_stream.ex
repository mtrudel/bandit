defmodule Bandit.HTTP2.Frame.RstStream do
  @moduledoc false

  defstruct stream_id: nil, error_code: nil

  @typedoc "An HTTP/2 RST_STREAM frame"
  @type t :: %__MODULE__{
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          error_code: Bandit.HTTP2.Errors.error_code()
        }

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, 0, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "RST_STREAM frame with zero stream_id (RFC9113§6.4)"}
  end

  def deserialize(_flags, stream_id, <<error_code::32>>) do
    {:ok, %__MODULE__{stream_id: stream_id, error_code: error_code}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, Bandit.HTTP2.Errors.frame_size_error(),
     "Invalid payload size in RST_STREAM frame (RFC9113§6.4)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    def serialize(%Bandit.HTTP2.Frame.RstStream{} = frame, _max_frame_size) do
      [{0x3, 0x0, frame.stream_id, <<frame.error_code::32>>}]
    end
  end
end
