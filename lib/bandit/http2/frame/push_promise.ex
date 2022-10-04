defmodule Bandit.HTTP2.Frame.PushPromise do
  @moduledoc false

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:error, Connection.error()}
  def deserialize(_flags, _stream, _payload) do
    {:error, {:connection, Errors.protocol_error(), "PUSH_PROMISE frame received (RFC7540§8.2)"}}
  end
end
