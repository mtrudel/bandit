defmodule Bandit.HTTP2.Frame.Continuation do
  @moduledoc false

  defstruct stream_id: nil,
            end_headers: false,
            fragment: nil

  import Bitwise

  alias Bandit.HTTP2.{Errors, Serializable}

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(),
      "CONTINUATION frame with zero stream_id (RFC7540§6.10)"}}
  end

  def deserialize(flags, stream_id, <<fragment::binary>>) do
    {:ok,
     %__MODULE__{stream_id: stream_id, end_headers: (flags &&& 0x04) == 0x04, fragment: fragment}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Continuation

    def serialize(%Continuation{} = frame, max_frame_size) do
      fragment_length = IO.iodata_length(frame.fragment)

      if fragment_length <= max_frame_size do
        [{0x9, 0x04, frame.stream_id, frame.fragment}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.fragment)

        [
          {0x9, 0x00, frame.stream_id, this_frame}
          | Serializable.serialize(
              %Continuation{stream_id: frame.stream_id, fragment: rest},
              max_frame_size
            )
        ]
      end
    end
  end
end
