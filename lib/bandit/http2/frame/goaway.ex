defmodule Bandit.HTTP2.Frame.Goaway do
  @moduledoc false

  defstruct last_stream_id: 0, error_code: 0, debug_data: <<>>

  alias Bandit.HTTP2.Constants

  def deserialize(
        _flags,
        0,
        <<_reserved::1, last_stream_id::31, error_code::32, debug_data::binary>>
      ) do
    {:ok,
     %__MODULE__{last_stream_id: last_stream_id, error_code: error_code, debug_data: debug_data}}
  end

  def deserialize(_flags, stream_id, _payload) when stream_id != 0 do
    {:error,
     {:connection, Constants.protocol_error(), "Invalid stream ID in GOAWAY frame (RFC7540§6.8)"}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error,
     {:connection, Constants.frame_size_error(),
      "GOAWAY frame with invalid payload size (RFC7540§6.8)"}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Goaway

    def serialize(%Goaway{
          last_stream_id: last_stream_id,
          error_code: error_code,
          debug_data: debug_data
        }) do
      {0x7, 0x0, 0, <<0x0::1, last_stream_id::31, error_code::32, debug_data::binary>>}
    end
  end
end
