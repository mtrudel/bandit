defmodule Bandit.HTTP2.Frame.Goaway do
  @moduledoc false

  defstruct last_stream_id: 0, error_code: 0, debug_data: <<>>

  @typedoc "An HTTP/2 GOAWAY frame"
  @type t :: %__MODULE__{
          last_stream_id: Bandit.HTTP2.Stream.stream_id(),
          error_code: Bandit.HTTP2.Errors.error_code(),
          debug_data: iodata()
        }

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(
        _flags,
        0,
        <<_reserved::1, last_stream_id::31, error_code::32, debug_data::binary>>
      ) do
    {:ok,
     %__MODULE__{last_stream_id: last_stream_id, error_code: error_code, debug_data: debug_data}}
  end

  def deserialize(_flags, stream_id, _payload) when stream_id != 0 do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "Invalid stream ID in GOAWAY frame (RFC9113§6.8)"}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, Bandit.HTTP2.Errors.frame_size_error(),
     "GOAWAY frame with invalid payload size (RFC9113§6.8)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    def serialize(%Bandit.HTTP2.Frame.Goaway{} = frame, _max_frame_size) do
      [
        {0x7, 0x0, 0,
         <<0x0::1, frame.last_stream_id::31, frame.error_code::32, frame.debug_data::binary>>}
      ]
    end
  end
end
