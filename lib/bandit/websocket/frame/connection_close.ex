defmodule Bandit.WebSocket.Frame.ConnectionClose do
  @moduledoc false

  defstruct code: nil, reason: <<>>

  @typedoc "A WebSocket status code"
  @type status_code :: non_neg_integer()

  @typedoc "A WebSocket connection close frame"
  @type t :: %__MODULE__{code: status_code(), reason: binary()}

  @spec deserialize(boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(true, <<>>) do
    {:ok, %__MODULE__{}}
  end

  def deserialize(true, <<code::16>>) do
    {:ok, %__MODULE__{code: code}}
  end

  def deserialize(true, <<code::16, reason::binary>>) when byte_size(reason) <= 123 do
    {:ok, %__MODULE__{code: code, reason: reason}}
  end

  def deserialize(true, _payload) do
    {:error, "Invalid connection close payload (RFC6455§5.5)"}
  end

  def deserialize(false, _payload) do
    {:error, "Cannot have a fragmented connection close frame (RFC6455§5.5)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame.ConnectionClose

    def serialize(%ConnectionClose{code: nil}), do: [{0x8, true, <<>>}]

    def serialize(%ConnectionClose{} = frame),
      do: [{0x8, true, [<<frame.code::16>>, frame.reason]}]
  end
end
