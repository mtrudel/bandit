defmodule Bandit.HTTP1.HeadParser do
  @moduledoc false
  # A fast path for reading an HTTP/1 request head, in plain binary pattern
  # matching. It covers the common shape of a request:
  #
  #   * an all-uppercase method,
  #   * an origin-form target (`/...`),
  #   * `HTTP/1.1` or `HTTP/1.0`,
  #   * token header names,
  #   * field values free of control bytes, and
  #   * CRLF line endings with no obs-fold continuation lines,
  #
  # all comfortably inside the configured limits. For those it returns exactly
  # what Bandit.HTTP1.Socket's decode_packet loop returns: the method as a
  # binary, an `{nil, nil, nil, path}` target, the version, and lowercase
  # header names with values already checked against RFC9110§5.5. Anything
  # else, including every malformed request, returns `:fallback`, so the
  # decode_packet loop makes every decision about it and raises every error.
  #
  # The whole head is parsed with a single binary match context: every
  # function on the scanning path starts with a binary match and receives
  # `rest` directly, and tokens are cut out of the original buffer with
  # `binary_part/3` by offset. Field values and request targets are scanned
  # 7 bytes at a time with SWAR tests.

  # The scanning functions carry the parse state as arguments, so that every
  # one starts with a binary match on `rest` and the head is parsed with a
  # single match context; that is where the speed comes from. What stays the
  # same for the whole head (the buffer, the request line and the limits)
  # rides along in one tuple, built once the request line is read.

  import Bitwise

  @type limits ::
          {max_request_line_length :: pos_integer(), max_header_length :: pos_integer(),
           max_header_count :: non_neg_integer()}

  @type result ::
          {:ok,
           {method :: binary(), {nil, nil, nil, path :: binary()}, :"HTTP/1.1" | :"HTTP/1.0"},
           Plug.Conn.headers(), rest :: binary()}
          | :more
          | :fallback

  @methods ~w(GET POST PUT DELETE HEAD OPTIONS PATCH)

  # Lowercase names recognised straight from the function head, in their
  # lowercase and canonical spellings, plus any other common spelling.
  @known_headers ~w(
    host user-agent accept accept-encoding accept-language accept-charset connection
    content-type content-length content-encoding cookie authorization cache-control pragma
    referer origin upgrade upgrade-insecure-requests if-none-match if-modified-since if-match
    if-range if-unmodified-since range transfer-encoding te expect keep-alive via forwarded date
    dnt priority x-forwarded-for x-forwarded-proto x-forwarded-host x-forwarded-port x-real-ip
    x-request-id x-requested-with x-csrf-token traceparent tracestate baggage sec-fetch-site
    sec-fetch-mode sec-fetch-user sec-fetch-dest sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform
    sec-websocket-key sec-websocket-version sec-websocket-extensions sec-websocket-protocol
  )
  @extra_spellings %{
    "te" => ["TE"],
    "dnt" => ["DNT"],
    "x-request-id" => ["X-Request-ID"],
    "x-real-ip" => ["X-Real-IP"],
    "x-csrf-token" => ["X-CSRF-Token"],
    "sec-ch-ua" => ["Sec-CH-UA"],
    "sec-ch-ua-mobile" => ["Sec-CH-UA-Mobile"],
    "sec-ch-ua-platform" => ["Sec-CH-UA-Platform"],
    "sec-websocket-key" => ["Sec-WebSocket-Key"],
    "sec-websocket-version" => ["Sec-WebSocket-Version"],
    "sec-websocket-extensions" => ["Sec-WebSocket-Extensions"],
    "sec-websocket-protocol" => ["Sec-WebSocket-Protocol"]
  }

  # decode_packet's packet_size is compared against slightly different
  # lengths for complete and incomplete lines; staying this far inside the
  # limit leaves the exact boundary to the decode_packet loop.
  @margin 4

  @doc false
  def known_headers, do: @known_headers

  defguardp is_upper(c) when c in ?A..?Z
  defguardp is_lower(c) when c in ?a..?z

  # tchar minus letters
  defguardp is_tother(c)
            when c in ?0..?9 or c == ?- or c == ?! or c == ?# or c == ?$ or c == ?% or
                   c == ?& or c == ?' or c == ?* or c == ?+ or c == ?. or c == ?^ or
                   c == ?_ or c == ?` or c == ?| or c == ?~

  # SWAR tests over 7 bytes packed into x (56 bits is the widest word that
  # stays a small integer on a 64-bit BEAM): "has a byte less than n" and
  # "has a DEL byte" (a zero byte once xor'd with 0x7F in every lane).
  @lo 0x01010101010101
  @hi 0x80808080808080
  @del 0x7F7F7F7F7F7F7F

  # Field-value bytes: VCHAR, obs-text and SP (HTAB takes the byte path).
  defguardp all_vchar_or_sp(x)
            when band(
                   bor(
                     band(x - 0x20 * @lo, bnot(x)),
                     band(bxor(x, @del) - @lo, bnot(bxor(x, @del)))
                   ),
                   @hi
                 ) == 0

  # Request-target bytes: anything above SP except DEL.
  defguardp all_target(x)
            when band(
                   bor(
                     band(x - 0x21 * @lo, bnot(x)),
                     band(bxor(x, @del) - @lo, bnot(bxor(x, @del)))
                   ),
                   @hi
                 ) == 0

  @doc """
  Parses the request head at the start of `bin`. Returns `:more` when `bin`
  holds the start of a head on the fast path but not all of it.
  """
  @spec parse(binary(), limits()) :: result()
  def parse(bin, limits) when is_binary(bin), do: request(bin, bin, limits)

  ## Request line

  defp more_line(buf, {max_line, _, _}) when byte_size(buf) + @margin <= max_line, do: :more
  defp more_line(_, _), do: :fallback

  for m <- @methods do
    size = byte_size(m)

    defp request(<<unquote(m), " /", rest::binary>>, buf, limits),
      do: target(rest, buf, unquote(size + 1), unquote(size + 2), unquote(m), limits)
  end

  defp request(<<c, rest::binary>>, buf, limits) when is_upper(c),
    do: method(rest, buf, 1, limits)

  defp request(<<>>, buf, limits), do: more_line(buf, limits)
  defp request(_, _, _), do: :fallback

  defp method(<<c, rest::binary>>, buf, pos, limits) when is_upper(c),
    do: method(rest, buf, pos + 1, limits)

  defp method(<<" /", rest::binary>>, buf, pos, limits),
    do: target(rest, buf, pos + 1, pos + 2, binary_part(buf, 0, pos), limits)

  defp method(<<>>, buf, _, limits), do: more_line(buf, limits)
  defp method(" ", buf, _, limits), do: more_line(buf, limits)
  defp method(_, _, _, _), do: :fallback

  defp target(<<x::56, rest::binary>>, buf, start, pos, m, limits) when all_target(x),
    do: target(rest, buf, start, pos + 7, m, limits)

  defp target(<<c, rest::binary>>, buf, start, pos, m, limits) when c > 0x20 and c != 0x7F,
    do: target(rest, buf, start, pos + 1, m, limits)

  defp target(<<" HTTP/1.1\r\n", rest::binary>>, buf, start, pos, m, limits),
    do: request_line(rest, buf, start, pos, m, :"HTTP/1.1", limits)

  defp target(<<" HTTP/1.0\r\n", rest::binary>>, buf, start, pos, m, limits),
    do: request_line(rest, buf, start, pos, m, :"HTTP/1.0", limits)

  defp target(rest, buf, _, _, _, limits), do: partial_version(rest, buf, ~c" HTTP/1.d\r", limits)

  defp request_line(rest, buf, start, pos, m, version, {max_line, _, _} = limits)
       when pos + 11 + @margin <= max_line do
    req = {m, {nil, nil, nil, binary_part(buf, start, pos - start)}, version}
    headers(rest, {buf, req, limits}, pos + 11, [], 0)
  end

  defp request_line(_, _, _, _, _, _, _), do: :fallback

  # :more if rest is a proper prefix of " HTTP/1.d\r\n" (d is 0 or 1).
  defp partial_version(<<c, rest::binary>>, buf, [?d | shape], limits) when c in ?0..?1,
    do: partial_version(rest, buf, shape, limits)

  defp partial_version(<<c, rest::binary>>, buf, [c | shape], limits),
    do: partial_version(rest, buf, shape, limits)

  defp partial_version(<<>>, buf, _, limits), do: more_line(buf, limits)
  defp partial_version(_, _, _, _), do: :fallback

  ## Headers

  defp more({buf, _, {_, max_header, _}}, line) do
    if byte_size(buf) - line + @margin <= max_header, do: :more, else: :fallback
  end

  for name <- @known_headers,
      canonical = name |> String.split("-") |> Enum.map_join("-", &String.capitalize/1),
      raw <- Enum.uniq([name, canonical | Map.get(@extra_spellings, name, [])]) do
    defp headers(<<unquote(raw), ?:, rest::binary>>, head, pos, acc, count),
      do: value_ws(rest, head, pos, pos + unquote(byte_size(raw) + 1), unquote(name), acc, count)
  end

  defp headers(<<"\r\n", rest::binary>>, {_, req, _}, _pos, acc, _count),
    do: {:ok, req, :lists.reverse(acc), rest}

  defp headers(<<c, rest::binary>>, head, pos, acc, count) when is_lower(c) or is_tother(c),
    do: name_lower(rest, head, pos, pos + 1, acc, count)

  defp headers(<<c, rest::binary>>, head, pos, acc, count) when is_upper(c),
    do: name_mixed(rest, head, pos, pos + 1, acc, count)

  defp headers(<<>>, head, pos, _acc, _count), do: more(head, pos)
  defp headers("\r", head, pos, _acc, _count), do: more(head, pos)
  defp headers(_, _, _, _, _), do: :fallback

  # The name scan tracks whether the raw name is already lowercase, so the
  # common case is a slice of the buffer with no second pass: name_lower has
  # seen no upper-case byte yet and name_mixed has.

  defp name_lower(<<c, rest::binary>>, head, start, pos, acc, count)
       when is_lower(c) or is_tother(c),
       do: name_lower(rest, head, start, pos + 1, acc, count)

  defp name_lower(<<c, rest::binary>>, head, start, pos, acc, count) when is_upper(c),
    do: name_mixed(rest, head, start, pos + 1, acc, count)

  defp name_lower(<<?:, rest::binary>>, {buf, _, _} = head, start, pos, acc, count) do
    name = binary_part(buf, start, pos - start)
    value_ws(rest, head, start, pos + 1, name, acc, count)
  end

  defp name_lower(<<>>, head, start, _, _acc, _count), do: more(head, start)
  defp name_lower(_, _, _, _, _, _), do: :fallback

  defp name_mixed(<<c, rest::binary>>, head, start, pos, acc, count)
       when is_lower(c) or is_upper(c) or is_tother(c),
       do: name_mixed(rest, head, start, pos + 1, acc, count)

  defp name_mixed(<<?:, rest::binary>>, {buf, _, _} = head, start, pos, acc, count) do
    name = downcase(binary_part(buf, start, pos - start))
    value_ws(rest, head, start, pos + 1, name, acc, count)
  end

  defp name_mixed(<<>>, head, start, _, _acc, _count), do: more(head, start)
  defp name_mixed(_, _, _, _, _, _), do: :fallback

  # A charlist turned into a heap binary is about twice as fast as an
  # appending loop for names this short.
  defp downcase(raw), do: :erlang.list_to_binary(lower(raw))

  defp lower(<<c, rest::binary>>) when is_upper(c), do: [c + 32 | lower(rest)]
  defp lower(<<c, rest::binary>>), do: [c | lower(rest)]
  defp lower(<<>>), do: []

  ## Values

  # `line` is where the header line starts, for the length limit.

  defp value_ws(<<c, rest::binary>>, head, line, pos, name, acc, count)
       when c == ?\s or c == ?\t,
       do: value_ws(rest, head, line, pos + 1, name, acc, count)

  defp value_ws(rest, head, line, pos, name, acc, count),
    do: value(rest, head, line, pos, pos, name, acc, count)

  # Skip 7 bytes at a time while all are valid field-value bytes; the
  # byte-wise clauses handle HTAB, the line end and anything invalid.
  defp value(<<x::56, rest::binary>>, head, line, start, pos, name, acc, count)
       when all_vchar_or_sp(x),
       do: value(rest, head, line, start, pos + 7, name, acc, count)

  defp value(<<c, rest::binary>>, head, line, start, pos, name, acc, count)
       when c == ?\t or (c >= 0x20 and c != 0x7F),
       do: value(rest, head, line, start, pos + 1, name, acc, count)

  # obs-fold continuation line
  defp value(<<"\r\n", c, _::binary>>, _, _, _, _, _, _, _) when c == ?\s or c == ?\t,
    do: :fallback

  # The header is not complete until the next byte rules out obs-fold.
  defp value("\r\n", head, line, _, _, _, _acc, _count), do: more(head, line)

  defp value(
         <<"\r\n", rest::binary>>,
         {buf, _, {_, max_header, max_count}} = head,
         line,
         start,
         pos,
         name,
         acc,
         count
       )
       when pos - line + 2 + @margin <= max_header and count < max_count do
    h = {name, binary_part(buf, start, pos - start)}
    headers(rest, head, pos + 2, [h | acc], count + 1)
  end

  defp value(<<>>, head, line, _, _, _, _acc, _count), do: more(head, line)
  defp value("\r", head, line, _, _, _, _acc, _count), do: more(head, line)
  defp value(_, _, _, _, _, _, _, _), do: :fallback
end
