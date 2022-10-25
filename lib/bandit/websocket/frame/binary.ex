defmodule Bandit.WebSocket.Frame.Binary do
  @moduledoc false

  defstruct fin: nil, compressed: false, data: <<>>

  @typedoc "A WebSocket binary frame"
  @type t :: %__MODULE__{fin: boolean(), compressed: boolean(), data: binary()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(fin, compressed, payload) do
    {:ok, %__MODULE__{fin: fin, compressed: compressed, data: payload}}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Binary

    def serialize(%Binary{} = frame), do: [{0x2, frame.fin, frame.data}]
  end
end
