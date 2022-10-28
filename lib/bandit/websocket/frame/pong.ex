defmodule Bandit.WebSocket.Frame.Pong do
  @moduledoc false

  defstruct data: <<>>

  @typedoc "A WebSocket pong frame"
  @type t :: %__MODULE__{data: binary()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(true, false, <<data::binary>>) when byte_size(data) <= 125 do
    {:ok, %__MODULE__{data: data}}
  end

  def deserialize(true, false, _payload) do
    {:error, "Invalid pong payload (RFC6455§5.5.3)"}
  end

  def deserialize(false, false, _payload) do
    {:error, "Cannot have a fragmented pong frame (RFC6455§5.5.3)"}
  end

  def deserialize(true, true, _payload) do
    {:error, "Cannot have a compressed pong frame (RFC7692§6.1)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.Pong

    def serialize(%Pong{} = frame), do: [{0xA, true, false, frame.data}]
  end
end
