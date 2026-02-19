defmodule Bandit.HTTP3.QPACK do
  @moduledoc false

  import Bitwise
  # Static-table-only QPACK encoder and decoder (RFC 9204).
  #
  # Uses the 99-entry static table from RFC 9204 Appendix A. No dynamic table
  # is maintained, which is valid per RFC 9204 §2.1.1 and covers the vast
  # majority of real-world HTTP headers efficiently.
  #
  # Encoding strategy (per header field):
  #   1. Exact {name, value} match in static table → Indexed Header Field
  #   2. Name-only match in static table → Literal with Static Name Reference
  #   3. No match → Literal without Name Reference
  #
  # Decoding handles: static indexed, static name reference, and
  # literal-without-name-reference fields. Dynamic table references and
  # Huffman-encoded names are rejected with an error tuple.

  # ---------------------------------------------------------------------------
  # Static table (RFC 9204 Appendix A, indices 0–98)
  # ---------------------------------------------------------------------------

  @static_table [
    {":authority", ""},                             # 0
    {":path", "/"},                                 # 1
    {"age", "0"},                                   # 2
    {"content-disposition", ""},                    # 3
    {"content-length", "0"},                        # 4
    {"cookie", ""},                                 # 5
    {"date", ""},                                   # 6
    {"etag", ""},                                   # 7
    {"if-modified-since", ""},                      # 8
    {"if-none-match", ""},                          # 9
    {"last-modified", ""},                          # 10
    {"link", ""},                                   # 11
    {"location", ""},                               # 12
    {"referer", ""},                                # 13
    {"set-cookie", ""},                             # 14
    {":method", "CONNECT"},                         # 15
    {":method", "DELETE"},                          # 16
    {":method", "GET"},                             # 17
    {":method", "HEAD"},                            # 18
    {":method", "OPTIONS"},                         # 19
    {":method", "POST"},                            # 20
    {":method", "PUT"},                             # 21
    {":scheme", "http"},                            # 22
    {":scheme", "https"},                           # 23
    {":status", "103"},                             # 24
    {":status", "200"},                             # 25
    {":status", "304"},                             # 26
    {":status", "404"},                             # 27
    {":status", "503"},                             # 28
    {"accept", "*/*"},                              # 29
    {"accept", "application/dns-message"},          # 30
    {"accept-encoding", "gzip, deflate, br"},       # 31
    {"accept-ranges", "bytes"},                     # 32
    {"access-control-allow-headers", "cache-control"},   # 33
    {"access-control-allow-headers", "content-type"},    # 34
    {"access-control-allow-origin", "*"},                # 35
    {"cache-control", "max-age=0"},                      # 36
    {"cache-control", "max-age=2592000"},                # 37
    {"cache-control", "max-age=604800"},                 # 38
    {"cache-control", "no-cache"},                       # 39
    {"cache-control", "no-store"},                       # 40
    {"cache-control", "public, max-age=31536000"},       # 41
    {"content-encoding", "br"},                          # 42
    {"content-encoding", "gzip"},                        # 43
    {"content-type", "application/dns-message"},         # 44
    {"content-type", "application/javascript"},          # 45
    {"content-type", "application/json"},                # 46
    {"content-type", "application/x-www-form-urlencoded"}, # 47
    {"content-type", "image/gif"},                       # 48
    {"content-type", "image/jpeg"},                      # 49
    {"content-type", "image/png"},                       # 50
    {"content-type", "text/css"},                        # 51
    {"content-type", "text/html; charset=utf-8"},        # 52
    {"content-type", "text/plain"},                      # 53
    {"content-type", "text/plain;charset=utf-8"},        # 54
    {"range", "bytes=0-"},                               # 55
    {"strict-transport-security", "max-age=31536000"},   # 56
    {"strict-transport-security", "max-age=31536000; includesubdomains"},          # 57
    {"strict-transport-security", "max-age=31536000; includesubdomains; preload"}, # 58
    {"vary", "accept-encoding"},                         # 59
    {"vary", "origin"},                                  # 60
    {"x-content-type-options", "nosniff"},               # 61
    {"x-xss-protection", "1; mode=block"},               # 62
    {":status", "100"},                                  # 63
    {":status", "204"},                                  # 64
    {":status", "206"},                                  # 65
    {":status", "302"},                                  # 66
    {":status", "400"},                                  # 67
    {":status", "403"},                                  # 68
    {":status", "421"},                                  # 69
    {":status", "425"},                                  # 70
    {":status", "500"},                                  # 71
    {"accept-language", ""},                             # 72
    {"access-control-allow-credentials", "FALSE"},       # 73
    {"access-control-allow-credentials", "TRUE"},        # 74
    {"access-control-allow-headers", "*"},               # 75
    {"access-control-allow-methods", "get"},                  # 76
    {"access-control-allow-methods", "get, post, options"},   # 77
    {"access-control-allow-methods", "options"},              # 78
    {"access-control-expose-headers", "content-length"},      # 79
    {"access-control-request-headers", "content-type"},       # 80
    {"access-control-request-method", "get"},                 # 81
    {"access-control-request-method", "post"},                # 82
    {"alt-svc", "clear"},                                     # 83
    {"authorization", ""},                                    # 84
    {"content-security-policy",
     "script-src 'none'; object-src 'none'; base-uri 'none'"},  # 85
    {"early-data", "1"},                                      # 86
    {"expect-ct", ""},                                        # 87
    {"forwarded", ""},                                        # 88
    {"if-range", ""},                                         # 89
    {"origin", ""},                                           # 90
    {"purpose", "prefetch"},                                  # 91
    {"server", ""},                                           # 92
    {"timing-allow-origin", "*"},                             # 93
    {"upgrade-insecure-requests", "1"},                       # 94
    {"user-agent", ""},                                       # 95
    {"x-forwarded-for", ""},                                  # 96
    {"x-frame-options", "deny"},                              # 97
    {"x-frame-options", "sameorigin"}                         # 98
  ]

  # ---------------------------------------------------------------------------
  # Compile-time lookup tables
  # ---------------------------------------------------------------------------

  # index → {name, value}  (for decoding)
  @by_index @static_table
            |> Enum.with_index()
            |> Map.new(fn {{n, v}, i} -> {i, {n, v}} end)

  # {name, value} → index  (exact match; first occurrence wins for encoding)
  @by_name_value @static_table
                 |> Enum.with_index()
                 |> Enum.reduce(%{}, fn {{n, v}, i}, acc ->
                   Map.put_new(acc, {n, v}, i)
                 end)

  # name → index  (name-only match; first occurrence wins for encoding)
  @by_name @static_table
           |> Enum.with_index()
           |> Enum.reduce(%{}, fn {{n, _v}, i}, acc ->
             Map.put_new(acc, n, i)
           end)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec encode_headers(Plug.Conn.headers()) :: binary()
  def encode_headers(headers) do
    # Header block prefix (RFC 9204 §4.5.1):
    #   Required Insert Count = 0  → encoded as 0x00
    #   S = 0, Delta Base = 0      → encoded as 0x00
    fields = headers |> Enum.map(&encode_field/1) |> IO.iodata_to_binary()
    <<0x00, 0x00, fields::binary>>
  end

  @spec decode_headers(binary()) :: {:ok, Plug.Conn.headers()} | {:error, term()}
  def decode_headers(data) do
    with {:ok, rest} <- skip_prefix(data) do
      decode_all(rest, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Encoding internals
  # ---------------------------------------------------------------------------

  defp encode_field({name, value}) do
    cond do
      # Prefer indexed reference when both name and value are in the static table
      (idx = Map.get(@by_name_value, {name, value})) != nil ->
        encode_indexed_static(idx)

      # Fall back to name reference + literal value
      (idx = Map.get(@by_name, name)) != nil ->
        encode_literal_name_ref_static(idx, value)

      # Full literal: name and value both encoded inline
      true ->
        encode_literal_new_name(name, value)
    end
  end

  # Indexed Header Field (RFC 9204 §4.5.2): 1 T IIIIII  (T=1 for static)
  # Wire: 0b11IIIIII with 6-bit integer prefix
  defp encode_indexed_static(idx) do
    encode_prefixed_int(idx, 6, 0xC0)
  end

  # Literal Header Field With Name Reference (RFC 9204 §4.5.4): 0 1 N T IIII
  # N=0 (indexing allowed), T=1 (static name ref), 4-bit integer prefix
  # Wire: 0b0101IIII
  defp encode_literal_name_ref_static(name_idx, value) do
    <<encode_prefixed_int(name_idx, 4, 0x50)::binary, encode_string(value)::binary>>
  end

  # Literal Header Field Without Name Reference (RFC 9204 §4.5.6): 0 0 1 N H LLL
  # N=0, H=0 (no Huffman), 3-bit integer prefix for name length
  # Wire: 0b00100LLL
  defp encode_literal_new_name(name, value) do
    <<encode_prefixed_int(byte_size(name), 3, 0x20)::binary, name::binary,
      encode_string(value)::binary>>
  end

  # String literal: H=0 (no Huffman), 7-bit integer prefix for length, then bytes
  defp encode_string(str) do
    <<encode_prefixed_int(byte_size(str), 7, 0x00)::binary, str::binary>>
  end

  # HPACK-style integer with N-bit prefix (RFC 7541 §5.1, used by QPACK per RFC 9204 §4.1.1)
  defp encode_prefixed_int(value, n, header) do
    max = (1 <<< n) - 1

    if value < max do
      <<header ||| value>>
    else
      <<header ||| max, encode_int_continuation(value - max)::binary>>
    end
  end

  # Continuation bytes: 7 bits per byte, little-endian, high bit set on all but last
  defp encode_int_continuation(v) when v < 128, do: <<v>>

  defp encode_int_continuation(v) do
    <<0x80 ||| (v &&& 0x7F), encode_int_continuation(v >>> 7)::binary>>
  end

  # ---------------------------------------------------------------------------
  # Decoding internals
  # ---------------------------------------------------------------------------

  # Parse and discard the header block prefix (RFC 9204 §4.5.1).
  # We don't use the dynamic table, so we only need to skip past the prefix.
  defp skip_prefix(data) do
    with {:ok, _ric, rest} <- decode_prefixed_int_byte(data, 8),
         {:ok, _delta_base, rest} <- decode_prefixed_int_byte(rest, 7) do
      {:ok, rest}
    end
  end

  defp decode_all(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all(data, acc) do
    case decode_field(data) do
      {:ok, header, rest} -> decode_all(rest, [header | acc])
      {:error, _} = err -> err
    end
  end

  # Indexed Header Field (RFC 9204 §4.5.2): bit 7 = 1
  defp decode_field(<<byte, rest::binary>>) when band(byte, 0x80) != 0 do
    t_static = (byte &&& 0x40) != 0
    partial = byte &&& 0x3F

    case decode_int_cont(partial, 6, rest) do
      {:ok, _idx, _rest} when not t_static ->
        {:error, :dynamic_table_not_supported}

      {:ok, idx, rest} ->
        case Map.get(@by_index, idx) do
          nil -> {:error, {:unknown_static_index, idx}}
          header -> {:ok, header, rest}
        end

      err ->
        err
    end
  end

  # Literal Header Field With Name Reference (RFC 9204 §4.5.4): bits 7-6 = 01
  defp decode_field(<<byte, rest::binary>>) when band(byte, 0xC0) == 0x40 do
    t_static = (byte &&& 0x10) != 0
    partial = byte &&& 0x0F

    case decode_int_cont(partial, 4, rest) do
      {:ok, _idx, _rest} when not t_static ->
        {:error, :dynamic_table_not_supported}

      {:ok, idx, rest} ->
        case Map.get(@by_index, idx) do
          nil ->
            {:error, {:unknown_static_name_index, idx}}

          {name, _} ->
            case decode_string(rest) do
              {:ok, value, rest} -> {:ok, {name, value}, rest}
              err -> err
            end
        end

      err ->
        err
    end
  end

  # Literal Header Field Without Name Reference (RFC 9204 §4.5.6): bits 7-5 = 001
  defp decode_field(<<byte, rest::binary>>) when band(byte, 0xE0) == 0x20 do
    huffman_name = (byte &&& 0x08) != 0
    partial = byte &&& 0x07

    if huffman_name do
      {:error, :huffman_name_not_supported}
    else
      case decode_int_cont(partial, 3, rest) do
        {:ok, name_len, rest} ->
          case rest do
            <<name::binary-size(name_len), rest::binary>> ->
              case decode_string(rest) do
                {:ok, value, rest} -> {:ok, {name, value}, rest}
                err -> err
              end

            _ ->
              {:error, :truncated_name}
          end

        err ->
          err
      end
    end
  end

  defp decode_field(<<byte, _::binary>>) do
    {:error, {:unsupported_representation, byte}}
  end

  defp decode_field(<<>>) do
    {:error, :truncated_header_block}
  end

  # String literal: H bit (high bit) + 7-bit prefix length + raw bytes
  defp decode_string(<<byte, rest::binary>>) do
    huffman = (byte &&& 0x80) != 0
    partial = byte &&& 0x7F

    case decode_int_cont(partial, 7, rest) do
      {:ok, _len, _rest} when huffman ->
        {:error, :huffman_not_supported}

      {:ok, len, rest} ->
        case rest do
          <<str::binary-size(len), rest::binary>> -> {:ok, str, rest}
          _ -> {:error, :truncated_string}
        end

      err ->
        err
    end
  end

  defp decode_string(_), do: {:error, :truncated_string}

  # Decode an HPACK-style integer starting from a fresh byte.
  # The high (8 - n) bits of the byte are the representation prefix;
  # the low n bits are the start of the integer value.
  defp decode_prefixed_int_byte(<<byte, rest::binary>>, n) do
    max = (1 <<< n) - 1
    partial = byte &&& max
    decode_int_cont(partial, n, rest)
  end

  defp decode_prefixed_int_byte(<<>>, _n), do: {:error, :truncated_integer}

  # Finish decoding: if partial equals the max prefix value, read continuation bytes.
  defp decode_int_cont(partial, n, rest) do
    max = (1 <<< n) - 1

    if partial < max do
      {:ok, partial, rest}
    else
      read_int_continuation(rest, 0, 0, max)
    end
  end

  defp read_int_continuation(<<byte, rest::binary>>, acc, shift, base) do
    acc = acc + ((byte &&& 0x7F) <<< shift)

    if (byte &&& 0x80) != 0 do
      read_int_continuation(rest, acc, shift + 7, base)
    else
      {:ok, base + acc, rest}
    end
  end

  defp read_int_continuation(<<>>, _acc, _shift, _base), do: {:error, :truncated_integer}
end
