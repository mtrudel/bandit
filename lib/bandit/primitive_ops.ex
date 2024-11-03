defmodule Bandit.PrimitiveOps do
  @moduledoc """
  Primitive operations behaviour
  """

  @doc """
  WebSocket masking according to [RFC6455§5.3](https://www.rfc-editor.org/rfc/rfc6455#section-5.3)
  """
  @callback ws_mask(payload :: binary(), mask :: integer()) :: binary()
end
