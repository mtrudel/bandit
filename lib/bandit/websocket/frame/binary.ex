defmodule Bandit.WebSocket.Frame.Binary do
  @moduledoc false

  defstruct fin: nil, data: <<>>

  @typedoc "A WebSocket binary frame"
  @type t :: %__MODULE__{fin: boolean(), data: binary()}

  @spec deserialize(boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(fin, payload) do
    {:ok, %__MODULE__{fin: fin, data: payload}}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Binary

    def serialize(%Binary{} = frame), do: [{0x2, frame.fin, frame.data}]
  end
end
