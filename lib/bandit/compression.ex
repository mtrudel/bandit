defmodule Bandit.Compression do
  @moduledoc false

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @spec compress(binary(), String.t()) :: {binary(), String.t() | nil}
  def compress(<<>>, _accept_encoding), do: {<<>>, nil}
  def compress(response, nil), do: {response, nil}

  def compress(response, accept_encoding) do
    accept_encoding = Plug.Conn.Utils.list(accept_encoding)
    do_compress(response, accept_encoding)
  end

  defp do_compress(response, ["deflate" | _]) do
    deflate_context = :zlib.open()
    :ok = :zlib.deflateInit(deflate_context)
    response = :zlib.deflate(deflate_context, response, :sync)
    {response, "deflate"}
  end

  defp do_compress(response, ["x-gzip" | _]), do: do_compress(response, ["gzip"])
  defp do_compress(response, ["gzip" | _]), do: {:zlib.gzip(response), "gzip"}

  defp do_compress(response, [_ | rest]), do: do_compress(response, rest)
  defp do_compress(response, []), do: {response, nil}
end
