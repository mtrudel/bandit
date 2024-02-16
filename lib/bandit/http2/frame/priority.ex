defmodule Bandit.HTTP2.Frame.Priority do
  @moduledoc false

  defstruct stream_id: nil, dependent_stream_id: nil, weight: nil

  @typedoc "An HTTP/2 PRIORITY frame"
  @type t :: %__MODULE__{
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          dependent_stream_id: Bandit.HTTP2.Stream.stream_id(),
          weight: non_neg_integer()
        }

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, 0, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "PRIORITY frame with zero stream_id (RFC9113§6.3)"}
  end

  def deserialize(_flags, stream_id, <<_reserved::1, dependent_stream_id::31, weight::8>>) do
    {:ok,
     %__MODULE__{stream_id: stream_id, dependent_stream_id: dependent_stream_id, weight: weight}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, Bandit.HTTP2.Errors.frame_size_error(),
     "Invalid payload size in PRIORITY frame (RFC9113§6.3)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    def serialize(%Bandit.HTTP2.Frame.Priority{} = frame, _max_frame_size) do
      [{0x2, 0x0, frame.stream_id, <<0::1, frame.dependent_stream_id::31, frame.weight::8>>}]
    end
  end
end
