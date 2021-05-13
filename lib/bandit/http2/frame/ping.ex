defmodule Bandit.HTTP2.Frame.Ping do
  @moduledoc false

  defstruct ack: false, payload: nil

  def deserialize(<<_flags::7, 0x1::1>>, 0, <<payload::binary-size(8)>>) do
    {:ok, %__MODULE__{ack: true, payload: payload}}
  end

  def deserialize(<<_flags::7, 0x0::1>>, 0, <<payload::binary-size(8)>>) do
    {:ok, %__MODULE__{ack: false, payload: payload}}
  end

  def deserialize(_flags, stream_id, _payload) when stream_id != 0 do
    {:error, 0, :PROTOCOL_ERROR, "Invalid stream ID in PING frame (RFC7540§6.7)"}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, 0, :FRAME_SIZE_ERROR, "PING frame with invalid payload size (RFC7540§6.7)"}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Ping

    def serialize(%Ping{ack: true, payload: payload}), do: {0x6, <<0x1>>, 0, payload}
    def serialize(%Ping{ack: false, payload: payload}), do: {0x6, <<0x0>>, 0, payload}
  end
end
