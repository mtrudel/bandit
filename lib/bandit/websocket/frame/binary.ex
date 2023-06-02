defmodule Bandit.WebSocket.Frame.Binary do
  @moduledoc false

  defstruct fin: nil, compressed: false, data: <<>>

  @typedoc "A WebSocket binary frame"
  @type t :: %__MODULE__{fin: boolean(), compressed: boolean(), data: iodata()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()}
  def deserialize(fin, compressed, payload) do
    {:ok, %__MODULE__{fin: fin, compressed: compressed, data: payload}}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame

    @spec serialize(@for.t()) :: [{Frame.opcode(), boolean(), boolean(), iodata()}]
    def serialize(%@for{} = frame), do: [{0x2, frame.fin, frame.compressed, frame.data}]
  end
end
