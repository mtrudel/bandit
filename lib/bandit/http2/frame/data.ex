defmodule Bandit.HTTP2.Frame.Data do
  @moduledoc false

  import Bandit.HTTP2.Frame.Flags

  defstruct stream_id: nil,
            end_stream: false,
            data: nil

  @typedoc "An HTTP/2 DATA frame"
  @type t :: %__MODULE__{
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          end_stream: boolean(),
          data: iodata()
        }

  @end_stream_bit 0
  @padding_bit 3

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, 0, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(), "DATA frame with zero stream_id (RFC9113§6.1)"}
  end

  def deserialize(flags, stream_id, <<padding_length::8, rest::binary>>)
      when set?(flags, @padding_bit) and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       data: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  def deserialize(flags, stream_id, <<data::binary>>) when clear?(flags, @padding_bit) do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       data: data
     }}
  end

  def deserialize(flags, _stream_id, <<_padding_length::8, _rest::binary>>)
      when set?(flags, @padding_bit) do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "DATA frame with invalid padding length (RFC9113§6.1)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    @end_stream_bit 0

    def serialize(%Bandit.HTTP2.Frame.Data{} = frame, max_frame_size) do
      data_length = IO.iodata_length(frame.data)

      if data_length <= max_frame_size do
        flags = if frame.end_stream, do: [@end_stream_bit], else: []
        [{0x0, set(flags), frame.stream_id, frame.data}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.data)

        [
          {0x0, 0x00, frame.stream_id, this_frame}
          | Bandit.HTTP2.Frame.Serializable.serialize(
              %Bandit.HTTP2.Frame.Data{
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
