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

  # Compressing chunked responses with zstd relies on :zstd.flush/1, which was added in OTP 29
  @zstd_streaming? Code.ensure_loaded?(:zstd) and function_exported?(:zstd, :flush, 1)

  @spec negotiate_content_encodings(nil | binary(), keyword()) :: [String.t()]
  def negotiate_content_encodings(nil, _), do: []

  def negotiate_content_encodings(accept_encoding, http_opts) do
    if Keyword.get(http_opts, :compress, true) do
      # Parse Accept-Encoding per RFC9110§12.5.3, honoring q-values (a value of q=0 means 'not
      # acceptable') and the '*' wildcard, and comparing codings case-insensitively. Returns the
      # codings the client is willing to accept, in our own preference order
      accepted = parse_accept_encoding(accept_encoding)
      wildcard_q = Enum.find_value(accepted, fn {coding, q} -> if coding == "*", do: q end)

      Keyword.get(http_opts, :response_encodings, @accepted_encodings)
      |> Enum.filter(fn encoding ->
        case List.keyfind(accepted, encoding, 0) do
          {_coding, q} -> q > 0
          nil -> wildcard_q != nil and wildcard_q > 0
        end
      end)
    else
      []
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

  # RFC9110§12.4.2: qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ), so a well-formed
  # q value is at most five characters long. Anything longer is malformed, and malformed q values
  # are leniently read as 1.0 rather than refusing the coding, since a client that bothered to list
  # a coding presumably accepts it
  @max_qvalue_length 5

  @spec quality_value([binary()]) :: float()
  defp quality_value(params) do
    Enum.find_value(params, 1.0, fn param ->
      case param |> String.trim() |> String.downcase(:ascii) |> String.split("=") do
        ["q", value] -> parse_qvalue(value)
        _ -> nil
      end
    end)
  end

  # Only a value within the grammar's length is handed to Float.parse/1. Besides being the lenient
  # reading above, this keeps overlong digit strings away from Float.parse/1, which raises rather
  # than returning :error once the integer part no longer fits in a float (309 digits and up).
  # Without the check, such a value in an Accept-Encoding header turned the request into a 500
  defp parse_qvalue(value) when byte_size(value) <= @max_qvalue_length do
    case Float.parse(value) do
      {q, _rest} -> q
      :error -> 1.0
    end
  end

  defp parse_qvalue(_value), do: 1.0

  def new(adapter, status, headers, empty_body?, streamable \\ false) do
    response_content_encoding_header = Bandit.Headers.get_header(headers, "content-encoding")

    headers = maybe_add_vary_header(adapter, status, headers)

    # 206 responses are excluded since compressing them would change the bytes relative to the
    # content-range the response advertises against the identity representation, corrupting
    # range reassembly at the client
    if status not in [204, 206, 304] && adapter.content_encodings != [] &&
         is_nil(response_content_encoding_header) &&
         !response_has_strong_etag(headers) && !response_indicates_no_transform(headers) &&
         !empty_body? do
      # Not every encoding can be used for every response (zstd can't compress chunked responses
      # before OTP 29), so use the first acceptable encoding that can
      identity = {headers, %__MODULE__{method: :identity}}

      Enum.find_value(candidate_encodings(adapter, streamable), identity, fn encoding ->
        case start_stream(encoding, adapter.opts.http, streamable) do
          {:ok, context} -> {[{"content-encoding", encoding} | headers], context}
          {:error, :unsupported_encoding} -> nil
        end
      end)
    else
      {headers, %__MODULE__{method: :identity}}
    end
  end

  # Unless compress_chunked is set, chunked responses are only compressed when deflate is the
  # preferred encoding, so that enabling gzip and zstd for them is opt-in
  defp candidate_encodings(adapter, true = _streamable) do
    if Keyword.get(adapter.opts.http, :compress_chunked, false),
      do: adapter.content_encodings,
      else: Enum.take_while(adapter.content_encodings, &(&1 == "deflate"))
  end

  defp candidate_encodings(adapter, false = _streamable), do: adapter.content_encodings

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
    {:ok, %__MODULE__{method: :deflate, lib_context: deflate_init(opts)}}
  end

  # Adding 16 to window_bits makes zlib write a gzip header and trailer instead of zlib ones
  defp start_stream(encoding, _opts, _streamable) when encoding in ~w(gzip x-gzip),
    do: {:ok, %__MODULE__{method: :gzip, lib_context: deflate_init(window_bits: 16 + 15)}}

  if Code.ensure_loaded?(:zstd) do
    defp start_stream("zstd", http_opts, streamable) when not streamable or @zstd_streaming? do
      opts = Keyword.get(http_opts, :zstd_options, %{})
      {:ok, zstd_context} = :zstd.context(:compress, opts)

      {:ok, %__MODULE__{method: :zstd, lib_context: zstd_context}}
    end
  end

  defp start_stream(_encoding, _opts, _streamable), do: {:error, :unsupported_encoding}

  defp deflate_init(opts) do
    deflate_context = :zlib.open()

    :zlib.deflateInit(
      deflate_context,
      Keyword.get(opts, :level, :default),
      :deflated,
      Keyword.get(opts, :window_bits, 15),
      Keyword.get(opts, :mem_level, 8),
      Keyword.get(opts, :strategy, :default)
    )

    deflate_context
  end

  def compress_chunk(chunk, %__MODULE__{method: :identity} = context), do: {chunk, context}

  def compress_chunk(chunk, %__MODULE__{} = context) do
    context = %{context | bytes_in: context.bytes_in + IO.iodata_length(chunk)}
    {compress_and_flush(context, chunk), context}
  end

  # Chunks are flushed so that the client can decode each one as soon as it arrives
  defp compress_and_flush(%__MODULE__{method: method, lib_context: lib_context}, chunk)
       when method in [:deflate, :gzip],
       do: :zlib.deflate(lib_context, chunk, :sync)

  if @zstd_streaming? do
    defp compress_and_flush(%__MODULE__{method: :zstd, lib_context: lib_context}, chunk) do
      compressed = zstd_stream(lib_context, chunk)
      {:continue, flushed} = :zstd.flush(lib_context)
      [compressed, flushed]
    end

    # :zstd.stream/2 returns whatever input it could not consume in a single call
    defp zstd_stream(zstd_context, data) do
      case :zstd.stream(zstd_context, data) do
        {:continue, output} -> [output]
        {:continue, remainder, output} -> [output | zstd_stream(zstd_context, remainder)]
      end
    end
  end

  # Finishes the compressed stream, with last_chunk as its final input
  def close(context, last_chunk \\ [])

  def close(%__MODULE__{method: :identity}, last_chunk), do: {last_chunk, %{}}

  def close(%__MODULE__{} = context, last_chunk) do
    {close_context(context, last_chunk),
     %{
       resp_compression_method: to_string(context.method),
       resp_uncompressed_body_bytes: context.bytes_in + IO.iodata_length(last_chunk)
     }}
  end

  defp close_context(%__MODULE__{method: method, lib_context: lib_context}, last_chunk)
       when method in [:deflate, :gzip] do
    last = :zlib.deflate(lib_context, last_chunk, :finish)
    :ok = :zlib.deflateEnd(lib_context)
    :zlib.close(lib_context)
    last
  end

  if Code.ensure_loaded?(:zstd) do
    defp close_context(%__MODULE__{method: :zstd, lib_context: lib_context}, last_chunk) do
      {:done, last} = :zstd.finish(lib_context, last_chunk)
      :zstd.close(lib_context)
      last
    end
  end
end
