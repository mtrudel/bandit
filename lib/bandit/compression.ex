defmodule Bandit.Compression do
  @moduledoc false

  defstruct method: nil, bytes_in: 0, lib_context: nil

  @typedoc "A struct containing the context for response compression"
  @type t :: %__MODULE__{
          method: :deflate | :gzip | :identity,
          bytes_in: non_neg_integer(),
          lib_context: term()
        }

  @spec negotiate_content_encoding(nil | binary(), boolean()) :: String.t() | nil
  def negotiate_content_encoding(nil, _), do: nil
  def negotiate_content_encoding(_, false), do: nil

  def negotiate_content_encoding(accept_encoding, true) do
    accept_encoding
    |> Plug.Conn.Utils.list()
    |> Enum.find(&(&1 in ~w(deflate gzip x-gzip)))
  end

  def new(adapter, status, headers, empty_body?, streamable \\ false) do
    response_content_encoding_header = Bandit.Headers.get_header(headers, "content-encoding")

    headers = maybe_add_vary_header(adapter, status, headers)

    if status not in [204, 304] && not is_nil(adapter.content_encoding) &&
         is_nil(response_content_encoding_header) &&
         !response_has_strong_etag(headers) && !response_indicates_no_transform(headers) &&
         !empty_body? do
      deflate_options = Keyword.get(adapter.opts.http, :deflate_options, [])

      case start_stream(adapter.content_encoding, deflate_options, streamable) do
        {:ok, context} -> {[{"content-encoding", adapter.content_encoding} | headers], context}
        {:error, :unsupported_encoding} -> {headers, %__MODULE__{method: :identity}}
      end
    else
      {headers, %__MODULE__{method: :identity}}
    end
  end

  defp maybe_add_vary_header(adapter, status, headers) do
    if status != 204 && Keyword.get(adapter.opts.http, :compress, true),
      do: [{"vary", "accept-encoding"} | headers],
      else: headers
  end

  defp response_has_strong_etag(headers) do
    case Bandit.Headers.get_header(headers, "etag") do
      nil -> false
      "\W" <> _rest -> false
      _strong_etag -> true
    end
  end

  defp response_indicates_no_transform(headers) do
    case Bandit.Headers.get_header(headers, "cache-control") do
      nil -> false
      header -> "no-transform" in Plug.Conn.Utils.list(header)
    end
  end

  defp start_stream("deflate", opts, _streamable) do
    deflate_context = :zlib.open()

    :zlib.deflateInit(
      deflate_context,
      Keyword.get(opts, :level, :default),
      :deflated,
      Keyword.get(opts, :window_bits, 15),
      Keyword.get(opts, :mem_level, 8),
      Keyword.get(opts, :strategy, :default)
    )

    {:ok, %__MODULE__{method: :deflate, lib_context: deflate_context}}
  end

  defp start_stream("x-gzip", _opts, false), do: {:ok, %__MODULE__{method: :gzip}}
  defp start_stream("gzip", _opts, false), do: {:ok, %__MODULE__{method: :gzip}}
  defp start_stream(_encoding, _opts, _streamable), do: {:error, :unsupported_encoding}

  def compress_chunk(chunk, %__MODULE__{method: :deflate} = context) do
    result = :zlib.deflate(context.lib_context, chunk, :sync)

    context =
      context
      |> Map.update!(:bytes_in, &(&1 + IO.iodata_length(chunk)))

    {result, context}
  end

  def compress_chunk(chunk, %__MODULE__{method: :gzip, lib_context: nil} = context) do
    result = :zlib.gzip(chunk)

    context =
      context
      |> Map.update!(:bytes_in, &(&1 + IO.iodata_length(chunk)))
      |> Map.put(:lib_context, :done)

    {result, context}
  end

  def compress_chunk(chunk, %__MODULE__{method: :identity} = context) do
    {chunk, context}
  end

  def close(%__MODULE__{} = context) do
    if context.method == :deflate, do: :zlib.close(context.lib_context)

    if context.method == :identity do
      %{}
    else
      %{
        resp_compression_method: to_string(context.method),
        resp_uncompressed_body_bytes: context.bytes_in
      }
    end
  end
end
