defmodule Bandit.HTTP2.Frame.RstStream do
  @moduledoc false

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  defstruct stream_id: nil, error_code: nil

  @typedoc "An HTTP/2 RST_STREAM frame"
  @type t :: %__MODULE__{
          stream_id: Stream.stream_id(),
          error_code: Errors.error_code()
        }

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Connection.error()}
  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(), "RST_STREAM frame with zero stream_id (RFC9113§6.4)"}}
  end

  def deserialize(_flags, stream_id, <<error_code::32>>) do
    {:ok, %__MODULE__{stream_id: stream_id, error_code: error_code}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Errors.frame_size_error(),
      "Invalid payload size in RST_STREAM frame (RFC9113§6.4)"}}
  end

  defimpl Frame.Serializable do
    alias Bandit.HTTP2.Frame.RstStream

    def serialize(%RstStream{} = frame, _max_frame_size) do
      [{0x3, 0x0, frame.stream_id, <<frame.error_code::32>>}]
    end
  end
end
