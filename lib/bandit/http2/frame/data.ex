defmodule Bandit.HTTP2.Frame.Data do
  @moduledoc false

  defstruct stream_id: nil,
            end_stream: false,
            data: nil

  import Bitwise

  alias Bandit.HTTP2.{Errors, Serializable}

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(), "DATA frame with zero stream_id (RFC7540§6.1)"}}
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
     {:connection, Errors.protocol_error(),
      "DATA frame with invalid padding length (RFC7540§6.1)"}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Data

    def serialize(%Data{} = frame, max_frame_size) do
      data_length = IO.iodata_length(frame.data)

      if data_length <= max_frame_size do
        flags = if frame.end_stream, do: 0x01, else: 0x00
        [{0x0, flags, frame.stream_id, frame.data}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.data)

        [
          {0x0, 0x00, frame.stream_id, this_frame}
          | Serializable.serialize(
              %Data{
                stream_id: frame.stream_id,
                end_stream: frame.end_stream,
                data: rest
              },
              max_frame_size
            )
        ]
      end
    end
  end
end
