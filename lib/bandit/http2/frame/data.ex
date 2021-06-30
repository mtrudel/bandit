defmodule Bandit.HTTP2.Frame.Data do
  @moduledoc false

  defstruct stream_id: nil,
            end_stream: false,
            data: nil

  import Bitwise

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Constants.protocol_error(), "DATA frame with zero stream_id (RFC7540§6.1)"}}
  end

  def deserialize(flags, stream_id, <<padding_length::8, rest::binary>>)
      when (flags &&& 0x08) == 0x08 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       data: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Neither padding nor priority
  def deserialize(flags, stream_id, <<data::binary>>) when (flags &&& 0x08) == 0x00 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       data: data
     }}
  end

  def deserialize(flags, _stream_id, <<_padding_length::8, _rest::binary>>)
      when (flags &&& 0x08) == 0x08 do
    {:error,
     {:connection, Constants.protocol_error(),
      "DATA frame with invalid padding length (RFC7540§6.1)"}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Data

    def serialize(%Data{} = frame) do
      flags = if frame.end_stream, do: 0x01, else: 0x00

      {0x0, flags, frame.stream_id, frame.data}
    end
  end
end
