defmodule Bandit.HTTP2.Frame.Priority do
  @moduledoc false

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  defstruct stream_id: nil, dependent_stream_id: nil, weight: nil

  @typedoc "An HTTP/2 PRIORITY frame"
  @type t :: %__MODULE__{
          stream_id: Stream.stream_id(),
          dependent_stream_id: Stream.stream_id(),
          weight: non_neg_integer()
        }

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Connection.error()}
  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(), "PRIORITY frame with zero stream_id (RFC9113§6.3)"}}
  end

  def deserialize(_flags, stream_id, <<_reserved::1, dependent_stream_id::31, weight::8>>) do
    {:ok,
     %__MODULE__{stream_id: stream_id, dependent_stream_id: dependent_stream_id, weight: weight}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Errors.frame_size_error(),
      "Invalid payload size in PRIORITY frame (RFC9113§6.3)"}}
  end

  defimpl Frame.Serializable do
    alias Bandit.HTTP2.Frame.Priority

    def serialize(%Priority{} = frame, _max_frame_size) do
      [{0x2, 0x0, frame.stream_id, <<0::1, frame.dependent_stream_id::31, frame.weight::8>>}]
    end
  end
end
