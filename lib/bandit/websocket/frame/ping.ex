defmodule Bandit.WebSocket.Frame.Ping do
  @moduledoc false

  defstruct data: <<>>

  @typedoc "A WebSocket ping frame"
  @type t :: %__MODULE__{data: iodata()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(true, false, <<data::binary>>) when byte_size(data) <= 125 do
    {:ok, %__MODULE__{data: data}}
  end

  def deserialize(true, false, _payload) do
    {:error, "Invalid ping payload (RFC6455§5.5.2)"}
  end

  def deserialize(false, false, _payload) do
    {:error, "Cannot have a fragmented ping frame (RFC6455§5.5.2)"}
  end

  def deserialize(_fin, true, _payload) do
    {:error, "Cannot have a compressed ping frame (RFC7692§6.1)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame

    @spec serialize(@for.t()) :: [{Frame.opcode(), boolean(), boolean(), iodata()}]
    def serialize(%@for{} = frame), do: [{0x9, true, false, frame.data}]
  end
end
