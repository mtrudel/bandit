defmodule Bandit.Compression do
  @moduledoc false

  @spec negotiate_content_encoding(nil | binary(), boolean()) :: String.t() | nil
  def negotiate_content_encoding(nil, _), do: nil
  def negotiate_content_encoding(_, false), do: nil

  def negotiate_content_encoding(accept_encoding, true) do
    accept_encoding
    |> Plug.Conn.Utils.list()
    |> Enum.find(&(&1 in ~w(deflate gzip x-gzip)))
  end

  @spec compress(iolist(), String.t(), Bandit.deflate_options()) :: iodata()
  def compress(response, "deflate", opts) do
    deflate_context = :zlib.open()

    try do
      :ok =
        :zlib.deflateInit(
          deflate_context,
          Keyword.get(opts, :level, :default),
          :deflated,
          Keyword.get(opts, :window_bits, 15),
          Keyword.get(opts, :mem_level, 8),
          Keyword.get(opts, :strategy, :default)
        )

      :zlib.deflate(deflate_context, response, :sync)
    after
      :zlib.close(deflate_context)
    end
  end

  def compress(response, "x-gzip", _opts), do: compress(response, "gzip", [])
  def compress(response, "gzip", _opts), do: :zlib.gzip(response)
end
