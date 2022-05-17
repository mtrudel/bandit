defmodule Bandit.WebSocket.Frame.Continuation do
  @moduledoc false

  defstruct fin: nil, data: <<>>

  @typedoc "A WebSocket continuation frame"
  @type t :: %__MODULE__{fin: boolean(), data: binary()}

  @spec deserialize(boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(fin, payload) do
    {:ok, %__MODULE__{fin: fin, data: payload}}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Continuation

    def serialize(%Continuation{} = frame), do: [{0x0, frame.fin, frame.data}]
  end
end
