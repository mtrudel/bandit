defmodule Bandit.HTTP2.Frame.Priority do
  @moduledoc false

  defstruct stream_id: nil, dependent_stream_id: nil, weight: nil

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Constants.protocol_error(), "PRIORITY frame with zero stream_id (RFC7540§6.3)"}}
  end

  def deserialize(_flags, stream_id, <<_reserved::1, dependent_stream_id::31, weight::8>>) do
    {:ok,
     %__MODULE__{stream_id: stream_id, dependent_stream_id: dependent_stream_id, weight: weight}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Constants.frame_size_error(),
      "Invalid payload size in PRIORITY frame (RFC7540§6.3)"}}
  end

  defimpl Bandit.HTTP2.Serializable do
    alias Bandit.HTTP2.Frame.Priority

    def serialize(%Priority{} = frame) do
      {0x2, 0x0, frame.stream_id, <<0::1, frame.dependent_stream_id::31, frame.weight::8>>}
    end
  end
end
