defmodule Bandit.HTTP2.Frame.Headers do
  @moduledoc false

  defstruct stream_id: nil,
            end_stream: false,
            end_headers: false,
            exclusive_dependency: false,
            stream_dependency: nil,
            weight: nil,
            fragment: nil

  import Bitwise

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error, 0, Constants.protocol_error(), "HEADERS frame with zero stream_id (RFC7540§6.2)"}
  end

  # Padding and priority
  def deserialize(
        flags,
        stream_id,
        <<padding_length::8, exclusive_dependency::1, stream_dependency::31, weight::8,
          rest::binary>>
      )
      when (flags &&& 0x28) == 0x28 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Padding but not priority
  def deserialize(flags, stream_id, <<padding_length::8, rest::binary>>)
      when (flags &&& 0x28) == 0x08 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Priority but not padding
  def deserialize(
        flags,
        stream_id,
        <<exclusive_dependency::1, stream_dependency::31, weight::8, fragment::binary>>
      )
      when (flags &&& 0x28) == 0x20 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: fragment
     }}
  end

  # Neither padding nor priority
  def deserialize(flags, stream_id, <<fragment::binary>>)
      when (flags &&& 0x28) == 0x00 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       fragment: fragment
     }}
  end

  def deserialize(
        flags,
        _stream_id,
        <<_padding_length::8, _exclusive_dependency::1, _stream_dependency::31, _weight::8,
          _rest::binary>>
      )
      when (flags &&& 0x28) == 0x28 do
    {:error, 0, Constants.protocol_error(),
     "HEADERS frame with invalid padding length (RFC7540§6.2)"}
  end

  def deserialize(flags, _stream_id, <<_padding_length::8, _rest::binary>>)
      when (flags &&& 0x28) == 0x08 do
    {:error, 0, Constants.protocol_error(),
     "HEADERS frame with invalid padding length (RFC7540§6.2)"}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Headers

    def serialize(
          %Headers{exclusive_dependency: false, stream_dependency: nil, weight: nil} = frame
        ) do
      flags = 0
      flags = if frame.end_stream, do: flags ||| 0x01, else: flags
      flags = if frame.end_headers, do: flags ||| 0x04, else: flags

      {0x1, flags, frame.stream_id, frame.fragment}
    end
  end
end
