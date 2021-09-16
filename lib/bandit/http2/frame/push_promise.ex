defmodule Bandit.HTTP2.Frame.PushPromise do
  @moduledoc false

  defstruct stream_id: nil,
            end_headers: false,
            promised_stream_id: nil,
            fragment: nil

  import Bitwise

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Constants.protocol_error(),
      "PUSH_PROMISE frame with zero stream_id (RFC7540§6.6)"}}
  end

  def deserialize(
        flags,
        stream_id,
        <<padding_length::8, 0::1, promised_stream_id::31, rest::binary>>
      )
      when (flags &&& 0x08) == 0x08 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_headers: (flags &&& 0x04) == 0x04,
       promised_stream_id: promised_stream_id,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  def deserialize(flags, stream_id, <<0::1, promised_stream_id::31, fragment::binary>>)
      when (flags &&& 0x08) == 0x00 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_headers: (flags &&& 0x04) == 0x04,
       promised_stream_id: promised_stream_id,
       fragment: fragment
     }}
  end

  def deserialize(
        flags,
        _stream_id,
        <<_padding_length::8, _reserved::1, _promised_stream_id::31, _rest::binary>>
      )
      when (flags &&& 0x08) == 0x08 do
    {:error,
     {:connection, Constants.protocol_error(),
      "PUSH_PROMISE frame with invalid padding length (RFC7540§6.6)"}}
  end

  defimpl Bandit.HTTP2.Serializable do
    alias Bandit.HTTP2.Frame.PushPromise

    def serialize(%PushPromise{} = frame) do
      flags = if frame.end_headers, do: 0x04, else: 0x00

      {0x5, flags, frame.stream_id,
       <<0::1, frame.promised_stream_id::31, frame.fragment::binary>>}
    end
  end
end
