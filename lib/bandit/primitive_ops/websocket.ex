defmodule Bandit.PrimitiveOps.WebSocket do
  @moduledoc """
  WebSocket primitive operations behaviour and default implementation
  """

  @doc """
  WebSocket masking according to [RFC6455§5.3](https://www.rfc-editor.org/rfc/rfc6455#section-5.3)
  """
  @callback ws_mask(payload :: binary(), mask :: integer()) :: binary()

  @behaviour __MODULE__

  # Note that masking is an involution, so we don't need a separate unmask function
  @impl true
  def ws_mask(payload, mask)
      when is_binary(payload) and is_integer(mask) and mask >= 0x00000000 and mask <= 0xFFFFFFFF do
    ws_mask(<<>>, payload, mask)
  end

  defp ws_mask(acc, <<h::32, rest::binary>>, mask) do
    ws_mask(<<acc::binary, (<<Bitwise.bxor(h, mask)::32>>)>>, rest, mask)
  end

  for size <- [24, 16, 8] do
    defp ws_mask(acc, <<h::unquote(size)>>, mask) do
      <<mask::unquote(size), _::binary>> = <<mask::32>>
      <<acc::binary, (<<Bitwise.bxor(h, mask)::unquote(size)>>)>>
    end
  end

  defp ws_mask(acc, <<>>, _mask) do
    acc
  end
end
