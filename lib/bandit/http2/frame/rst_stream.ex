defmodule Bandit.HTTP2.Frame.RstStream do
  @moduledoc false

  defstruct stream_id: nil, error_code: nil

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Constants.protocol_error(),
      "RST_STREAM frame with zero stream_id (RFC7540§6.4)"}}
  end

  def deserialize(_flags, stream_id, <<error_code::32>>) do
    {:ok, %__MODULE__{stream_id: stream_id, error_code: error_code}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Constants.frame_size_error(),
      "Invalid payload size in RST_STREAM frame (RFC7540§6.4)"}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.RstStream

    def serialize(%RstStream{} = frame), do: {0x3, 0x0, frame.stream_id, <<frame.error_code::32>>}
  end
end
