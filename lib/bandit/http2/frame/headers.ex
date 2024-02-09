defmodule Bandit.HTTP2.Frame.Headers do
  @moduledoc false

  import Bandit.HTTP2.Frame.Flags

  defstruct stream_id: nil,
            end_stream: false,
            end_headers: false,
            exclusive_dependency: false,
            stream_dependency: nil,
            weight: nil,
            fragment: nil

  @typedoc "An HTTP/2 HEADERS frame"
  @type t :: %__MODULE__{
          stream_id: Bandit.HTTP2.Stream.stream_id(),
          end_stream: boolean(),
          end_headers: boolean(),
          exclusive_dependency: boolean(),
          stream_dependency: Bandit.HTTP2.Stream.stream_id() | nil,
          weight: non_neg_integer() | nil,
          fragment: iodata()
        }

  @end_stream_bit 0
  @end_headers_bit 2
  @padding_bit 3
  @priority_bit 5

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, 0, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "HEADERS frame with zero stream_id (RFC9113§6.2)"}
  end

  # Padding and priority
  def deserialize(
        flags,
        stream_id,
        <<padding_length::8, exclusive_dependency::1, stream_dependency::31, weight::8,
          rest::binary>>
      )
      when set?(flags, @padding_bit) and set?(flags, @priority_bit) and
             byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       end_headers: set?(flags, @end_headers_bit),
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Padding but not priority
  def deserialize(flags, stream_id, <<padding_length::8, rest::binary>>)
      when set?(flags, @padding_bit) and clear?(flags, @priority_bit) and
             byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       end_headers: set?(flags, @end_headers_bit),
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Any other case where padding is set
  def deserialize(flags, _stream_id, <<_padding_length::8, _rest::binary>>)
      when set?(flags, @padding_bit) do
    {:error, Bandit.HTTP2.Errors.protocol_error(),
     "HEADERS frame with invalid padding length (RFC9113§6.2)"}
  end

  def deserialize(
        flags,
        stream_id,
        <<exclusive_dependency::1, stream_dependency::31, weight::8, fragment::binary>>
      )
      when set?(flags, @priority_bit) do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       end_headers: set?(flags, @end_headers_bit),
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: fragment
     }}
  end

  def deserialize(flags, stream_id, <<fragment::binary>>)
      when clear?(flags, @priority_bit) and clear?(flags, @padding_bit) do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: set?(flags, @end_stream_bit),
       end_headers: set?(flags, @end_headers_bit),
       fragment: fragment
     }}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    @end_stream_bit 0
    @end_headers_bit 2

    def serialize(
          %Bandit.HTTP2.Frame.Headers{
            exclusive_dependency: false,
            stream_dependency: nil,
            weight: nil
          } =
            frame,
          max_frame_size
        ) do
      flags = if frame.end_stream, do: [@end_stream_bit], else: []

      fragment_length = IO.iodata_length(frame.fragment)

      if fragment_length <= max_frame_size do
        [{0x1, set([@end_headers_bit | flags]), frame.stream_id, frame.fragment}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.fragment)

        [
          {0x1, set(flags), frame.stream_id, this_frame}
          | Bandit.HTTP2.Frame.Serializable.serialize(
              %Bandit.HTTP2.Frame.Continuation{stream_id: frame.stream_id, fragment: rest},
              max_frame_size
            )
        ]
      end
    end
  end
end
