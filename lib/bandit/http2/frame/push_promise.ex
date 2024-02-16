defmodule Bandit.HTTP2.Frame.PushPromise do
  @moduledoc false

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(_flags, _stream, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(), "PUSH_PROMISE frame received (RFC9113§8.4)"}
  end
end
