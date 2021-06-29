defmodule Bandit.HTTP2.Frame.Unknown do
  @moduledoc false

  defstruct type: nil,
            flags: nil,
            stream_id: nil,
            payload: nil

  # Note this is arity 4
  def deserialize(type, flags, stream_id, payload) do
    {:ok, %__MODULE__{type: type, flags: flags, stream_id: stream_id, payload: payload}}
  end
end
