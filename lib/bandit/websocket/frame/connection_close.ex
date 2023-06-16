defmodule Bandit.WebSocket.Frame.ConnectionClose do
  @moduledoc false

  defstruct code: nil, reason: <<>>

  @typedoc "A WebSocket status code, or none at all"
  @type status_code :: non_neg_integer() | nil

  @typedoc "A WebSocket connection close frame"
  @type t :: %__MODULE__{code: status_code(), reason: binary()}

  @spec deserialize(boolean(), boolean(), iodata()) :: {:ok, t()} | {:error, term()}
  def deserialize(true, false, <<>>) do
    {:ok, %__MODULE__{}}
  end

  def deserialize(true, false, <<code::16>>) do
    {:ok, %__MODULE__{code: code}}
  end

  def deserialize(true, false, <<code::16, reason::binary>>) when byte_size(reason) <= 123 do
    if String.valid?(reason) do
      {:ok, %__MODULE__{code: code, reason: reason}}
    else
      {:error, "Received non UTF-8 connection close frame (RFC6455§5.5.1)"}
    end
  end

  def deserialize(true, false, _payload) do
    {:error, "Invalid connection close payload (RFC6455§5.5)"}
  end

  def deserialize(false, false, _payload) do
    {:error, "Cannot have a fragmented connection close frame (RFC6455§5.5)"}
  end

  def deserialize(true, true, _payload) do
    {:error, "Cannot have a compressed connection close frame (RFC7692§6.1)"}
  end

  defimpl Bandit.WebSocket.Frame.Serializable do
    alias Bandit.WebSocket.Frame

    @spec serialize(@for.t()) :: [{Frame.opcode(), boolean(), boolean(), iodata()}]
    def serialize(%@for{code: nil}), do: [{0x8, true, false, <<>>}]
    def serialize(%@for{reason: nil} = frame), do: [{0x8, true, false, <<frame.code::16>>}]
    def serialize(%@for{} = frame), do: [{0x8, true, false, [<<frame.code::16>>, frame.reason]}]
  end
end
