defmodule Bandit.HTTP2.Frame.Continuation do
  @moduledoc false

  import Bandit.HTTP2.Frame.Flags

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  defstruct stream_id: nil,
            end_headers: false,
            fragment: nil

  @typedoc "An HTTP/2 CONTINUATION frame"
  @type t :: %__MODULE__{
          stream_id: Stream.stream_id(),
          end_headers: boolean(),
          fragment: iodata()
        }

  @end_headers_bit 2

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Connection.error()}
  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(),
      "CONTINUATION frame with zero stream_id (RFC9113§6.10)"}}
  end

  def deserialize(flags, stream_id, <<fragment::binary>>) do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_headers: set?(flags, @end_headers_bit),
       fragment: fragment
     }}
  end

  defimpl Frame.Serializable do
    alias Bandit.HTTP2.Frame.Continuation

    @end_headers_bit 2

    def serialize(%Continuation{} = frame, max_frame_size) do
      fragment_length = IO.iodata_length(frame.fragment)

      if fragment_length <= max_frame_size do
        [{0x9, set([@end_headers_bit]), frame.stream_id, frame.fragment}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.fragment)

        [
          {0x9, 0x00, frame.stream_id, this_frame}
          | Frame.Serializable.serialize(
              %Continuation{stream_id: frame.stream_id, fragment: rest},
              max_frame_size
            )
        ]
      end
    end
  end
end
