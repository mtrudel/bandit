defmodule Bandit.Compression do
  @moduledoc false

  defstruct method: nil, bytes_in: 0, lib_context: nil

  @typedoc "A struct containing the context for response compression"
  @type t :: %__MODULE__{
          method: :deflate | :gzip | :identity | :zstd,
          bytes_in: non_neg_integer(),
          lib_context: term()
        }

  @accepted_encodings ~w(gzip x-gzip deflate)

  if Code.ensure_loaded?(:zstd) do
    @accepted_encodings ~w(zstd) ++ @accepted_encodings
  end

  @spec negotiate_content_encoding(nil | binary(), keyword()) :: String.t() | nil
  def negotiate_content_encoding(nil, _), do: nil

  def negotiate_content_encoding(accept_encoding, http_opts) do
    if Keyword.get(http_opts, :compress, true) do
      # Parse Accept-Encoding per RFC9110§12.5.3, honoring q-values (a value of q=0 means 'not
      # acceptable') and the '*' wildcard, and comparing codings case-insensitively. Among the
      # codings the client is willing to accept, we pick the first in our own preference order
      accepted = parse_accept_encoding(accept_encoding)
      wildcard_q = Enum.find_value(accepted, fn {coding, q} -> if coding == "*", do: q end)

      Keyword.get(http_opts, :response_encodings, @accepted_encodings)
      |> Enum.find(fn encoding ->
        case List.keyfind(accepted, encoding, 0) do
          {_coding, q} -> q > 0
          nil -> wildcard_q != nil and wildcard_q > 0
        end
      end)
    else
      nil
    end
  end

  @spec parse_accept_encoding(binary()) :: [{binary(), float()}]
  defp parse_accept_encoding(accept_encoding) do
    accept_encoding
    |> Plug.Conn.Utils.list()
    |> Enum.map(fn element ->
      case String.split(element, ";") do
        [coding] -> {normalize_coding(coding), 1.0}
        [coding | params] -> {normalize_coding(coding), quality_value(params)}
      end
    end)
  end

  @spec normalize_coding(binary()) :: binary()
  defp normalize_coding(coding), do: coding |> String.trim() |> String.downcase(:ascii)

  # Per RFC9110§12.4.2. Malformed q values are leniently read as 1.0 rather than refusing the
  # coding, since a client that bothered to list a coding presumably accepts it
  @spec quality_value([binary()]) :: float()
  defp quality_value(params) do
    Enum.find_value(params, 1.0, fn param ->
      case param |> String.trim() |> String.downcase(:ascii) |> String.split("=") do
        ["q", value] ->
          case Float.parse(value) do
            {q, _rest} -> q
            :error -> 1.0
          end

        _ ->
          nil
      end
    end)
  end

  def new(adapter, status, headers, empty_body?, streamable \\ false) do
    response_content_encoding_header = Bandit.Headers.get_header(headers, "content-encoding")

    headers = maybe_add_vary_header(adapter, status, headers)

    if status not in [204, 304] && not is_nil(adapter.content_encoding) &&
         is_nil(response_content_encoding_header) &&
         !response_has_strong_etag(headers) && !response_indicates_no_transform(headers) &&
         !empty_body? do
      case start_stream(adapter.content_encoding, adapter.opts.http, streamable) do
        {:ok, context} -> {[{"content-encoding", adapter.content_encoding} | headers], context}
        {:error, :unsupported_encoding} -> {headers, %__MODULE__{method: :identity}}
      end
    else
      {headers, %__MODULE__{method: :identity}}
    end
  end

  defp maybe_add_vary_header(adapter, status, headers) do
    if status != 204 && Keyword.get(adapter.opts.http, :compress, true) &&
         !Bandit.Headers.header_contains_token?(headers, "vary", "accept-encoding"),
       do: [{"vary", "accept-encoding"} | headers],
       else: headers
  end

  defp response_has_strong_etag(headers) do
    case Bandit.Headers.get_header(headers, "etag") do
      nil -> false
      "W/" <> _rest -> false
      _strong_etag -> true
    end
  end

  defp response_indicates_no_transform(headers) do
    Bandit.Headers.header_contains_token?(headers, "cache-control", "no-transform")
  end

  defp start_stream("deflate", http_opts, _streamable) do
    opts = Keyword.get(http_opts, :deflate_options, [])
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

  if Code.ensure_loaded?(:zstd) do
    defp start_stream("zstd", http_opts, false) do
      opts = Keyword.get(http_opts, :zstd_options, %{})
      {:ok, zstd_context} = :zstd.context(:compress, opts)

      {:ok, %__MODULE__{method: :zstd, lib_context: zstd_context}}
    end
  end

  defp start_stream(_encoding, _opts, _streamable), do: {:error, :unsupported_encoding}

  def compress_chunk(chunk, %__MODULE__{method: :deflate} = context) do
    result = :zlib.deflate(context.lib_context, chunk, :sync)

    context =
      context
      |> Map.update!(:bytes_in, &(&1 + IO.iodata_length(chunk)))

    {result, context}
  end

  if Code.ensure_loaded?(:zstd) do
    def compress_chunk(chunk, %__MODULE__{method: :zstd} = context) do
      result = :zstd.compress(chunk, context.lib_context)

      context =
        context
        |> Map.update!(:bytes_in, &(&1 + IO.iodata_length(chunk)))

      {result, context}
    end
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
    chunk = close_context(context)

    if context.method == :identity do
      {chunk, %{}}
    else
      {chunk,
       %{
         resp_compression_method: to_string(context.method),
         resp_uncompressed_body_bytes: context.bytes_in
       }}
    end
  end

  defp close_context(%__MODULE__{method: :deflate, lib_context: lib_context}) do
    last = :zlib.deflate(lib_context, [], :finish)
    :ok = :zlib.deflateEnd(lib_context)
    :zlib.close(lib_context)
    last
  end

  if Code.ensure_loaded?(:zstd) do
    defp close_context(%__MODULE__{method: :zstd, lib_context: lib_context}) do
      :zstd.close(lib_context)
      []
    end
  end

  defp close_context(_context), do: []
end
