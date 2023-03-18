defmodule Bandit.Compression do
  @moduledoc false

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @spec compress(binary(), String.t(), keyword()) :: {binary(), String.t() | nil}
  def compress(<<>>, _accept_encoding, _opts), do: {<<>>, nil}
  def compress(response, nil, _opts), do: {response, nil}

  def compress(response, accept_encoding, opts) do
    accept_encoding = Plug.Conn.Utils.list(accept_encoding)
    do_compress(response, accept_encoding, opts)
  end

  defp do_compress(response, ["deflate" | _], opts) do
    deflate_context = :zlib.open()

    :ok =
      :zlib.deflateInit(
        deflate_context,
        Keyword.get(opts, :level, :default),
        :deflated,
        Keyword.get(opts, :window_bits, 15),
        Keyword.get(opts, :mem_level, 8),
        Keyword.get(opts, :strategy, :default)
      )

    response = :zlib.deflate(deflate_context, response, :sync)
    {response, "deflate"}
  end

  defp do_compress(response, ["x-gzip" | _], opts), do: do_compress(response, ["gzip"], opts)
  defp do_compress(response, ["gzip" | _], _opts), do: {:zlib.gzip(response), "gzip"}

  defp do_compress(response, [_ | rest], opts), do: do_compress(response, rest, opts)
  defp do_compress(response, [], _opts), do: {response, nil}
end
