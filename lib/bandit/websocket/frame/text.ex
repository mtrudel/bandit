defmodule Bandit.WebSocket.Frame.Text do
  @moduledoc false

  defstruct fin: nil, compressed: false, data: <<>>

  @typedoc "A WebSocket text frame"
  @type t :: %__MODULE__{fin: boolean(), compressed: boolean(), data: binary()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(fin, compressed, payload) do
    {:ok, %__MODULE__{fin: fin, compressed: compressed, data: payload}}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Text

    def serialize(%Text{} = frame), do: [{0x1, frame.fin, frame.compressed, frame.data}]
  end
end
