defmodule Bandit.HTTP2.Frame.Continuation do
  @moduledoc false

  defstruct stream_id: nil,
            end_headers: false,
            fragment: nil

  import Bitwise

  alias Bandit.HTTP2.Constants

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Constants.protocol_error(),
      "CONTINUATION frame with zero stream_id (RFC7540§6.10)"}}
  end

  def deserialize(flags, stream_id, <<fragment::binary>>) do
    {:ok,
     %__MODULE__{stream_id: stream_id, end_headers: (flags &&& 0x04) == 0x04, fragment: fragment}}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Continuation

    def serialize(%Continuation{} = frame) do
      flags = if frame.end_headers, do: 0x04, else: 0x00

      {0x9, flags, frame.stream_id, frame.fragment}
    end
  end
end
