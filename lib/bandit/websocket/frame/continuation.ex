defmodule Bandit.WebSocket.Frame.Continuation do
  @moduledoc false

  defstruct fin: nil, data: <<>>

  @typedoc "A WebSocket continuation frame"
  @type t :: %__MODULE__{fin: boolean(), data: iodata()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(fin, false, payload) do
    {:ok, %__MODULE__{fin: fin, data: payload}}
  end

  def deserialize(_fin, true, _payload) do
    {:error, "Cannot have a compressed continuation frame (RFC7692§6.1)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame

    @spec serialize(@for.t()) :: [{Frame.opcode(), boolean(), boolean(), iodata()}]
    def serialize(%@for{} = frame), do: [{0x0, frame.fin, false, frame.data}]
  end
end
