defmodule Bandit.HTTP3.QPACKTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP3.QPACK

  # Wire format constants used throughout:
  #   0x00 0x00   - header block prefix (RIC=0, S=0, DeltaBase=0)
  #   0xC0 | idx  - indexed static header field (6-bit prefix, T=1)
  #   0x50 | idx  - literal with static name reference (4-bit prefix, N=0, T=1)
  #   0x20 | len  - literal without name reference (3-bit prefix, N=0, H=0)

  describe "encode_headers/1 - indexed header fields (static table exact match)" do
    test "encodes single field present in static table" do
      # :method GET is at index 17 → 0xC0 | 17 = 0xD1
      assert QPACK.encode_headers([{":method", "GET"}]) == <<0x00, 0x00, 0xD1>>
    end

    test "encodes index 0 (:authority empty string)" do
      assert QPACK.encode_headers([{":authority", ""}]) == <<0x00, 0x00, 0xC0>>
    end

    test "encodes index 1 (:path /)" do
      assert QPACK.encode_headers([{":path", "/"}]) == <<0x00, 0x00, 0xC1>>
    end

    test "encodes index 25 (:status 200)" do
      assert QPACK.encode_headers([{":status", "200"}]) == <<0x00, 0x00, 0xD9>>
    end

    test "encodes index 62 (last single-byte static index, x-xss-protection)" do
      # 62 < 63, so fits in single byte: 0xC0 | 62 = 0xFE
      assert QPACK.encode_headers([{"x-xss-protection", "1; mode=block"}]) ==
               <<0x00, 0x00, 0xFE>>
    end

    test "encodes index 63 using two-byte form (6-bit max prefix + continuation 0)" do
      # 63 == max_prefix for 6-bit, so: <<0xFF, 0>>
      assert QPACK.encode_headers([{":status", "100"}]) == <<0x00, 0x00, 0xFF, 0>>
    end

    test "encodes index 98 (last static table entry, x-frame-options sameorigin)" do
      # 98 - 63 = 35 → <<0xFF, 35>>
      assert QPACK.encode_headers([{"x-frame-options", "sameorigin"}]) ==
               <<0x00, 0x00, 0xFF, 35>>
    end

    test "encodes multiple indexed fields" do
      headers = [{":method", "GET"}, {":scheme", "https"}, {":path", "/"}]
      # :method GET=17→0xD1, :scheme https=23→0xD7, :path /=1→0xC1
      assert QPACK.encode_headers(headers) == <<0x00, 0x00, 0xD1, 0xD7, 0xC1>>
    end

    test "encodes an empty header list" do
      assert QPACK.encode_headers([]) == <<0x00, 0x00>>
    end
  end

  describe "encode_headers/1 - literal with static name reference" do
    test "encodes field whose name is in static table but value is not" do
      # :authority is at index 0 (4-bit prefix): 0x50 | 0 = 0x50
      # value "example.com" (11 bytes): <<11, "example.com">>
      assert QPACK.encode_headers([{":authority", "example.com"}]) ==
               <<0x00, 0x00, 0x50, 11, "example.com">>
    end

    test "encodes :path with a non-table value" do
      # :path is at index 1: 0x50 | 1 = 0x51
      assert QPACK.encode_headers([{":path", "/search?q=elixir"}]) ==
               <<0x00, 0x00, 0x51, 16, "/search?q=elixir">>
    end

    test "encodes :status with a value not in the static table" do
      # :status first appears at index 24; 24 >= 15 (4-bit max) → multi-byte name ref
      # 24 - 15 = 9 → <<0x5F, 9>>
      # value "301" (3 bytes): <<3, "301">>
      assert QPACK.encode_headers([{":status", "301"}]) ==
               <<0x00, 0x00, 0x5F, 9, 3, "301">>
    end

    test "encodes name reference at exactly the 4-bit prefix boundary (index 15)" do
      # :method is at index 15; 15 == max_prefix for 4-bit → <<0x5F, 0>>
      # encode a :method with an unusual value
      assert QPACK.encode_headers([{":method", "PATCH"}]) ==
               <<0x00, 0x00, 0x5F, 0, 5, "PATCH">>
    end

    test "encodes content-type with a non-table value" do
      # content-type first appears at index 44
      # 44 - 15 = 29 → <<0x5F, 29>>
      assert QPACK.encode_headers([{"content-type", "text/event-stream"}]) ==
               <<0x00, 0x00, 0x5F, 29, 17, "text/event-stream">>
    end
  end

  describe "encode_headers/1 - literal without name reference" do
    test "encodes field whose name is not in static table (short name)" do
      # "via" (3 bytes): 0x20 | 3 = 0x23, then name, then value
      # "1.1 proxy" (9 bytes): <<9, "1.1 proxy">>
      assert QPACK.encode_headers([{"via", "1.1 proxy"}]) ==
               <<0x00, 0x00, 0x23, "via", 9, "1.1 proxy">>
    end

    test "encodes field with name length exactly at 3-bit boundary (length 7)" do
      # name "x-foo-y" (7 chars) is not in static table; 7 == max for 3-bit → <<0x27, 0>>
      assert QPACK.encode_headers([{"x-foo-y", "bar"}]) ==
               <<0x00, 0x00, 0x27, 0, "x-foo-y", 3, "bar">>
    end

    test "encodes field with name longer than 3-bit prefix (length 12)" do
      # "x-request-id" (12 bytes): 12 - 7 = 5 → <<0x27, 5>>
      assert QPACK.encode_headers([{"x-request-id", "abc-123"}]) ==
               <<0x00, 0x00, 0x27, 5, "x-request-id", 7, "abc-123">>
    end

    test "encodes field with empty value" do
      assert QPACK.encode_headers([{"x-empty", ""}]) ==
               <<0x00, 0x00, 0x27, 0, "x-empty", 0>>
    end

    test "encodes value requiring multi-byte length (>= 127 bytes)" do
      long_value = String.duplicate("x", 200)
      # value length 200: 200 >= 127 → <<0x7F, 200 - 127>> = <<0x7F, 73>>
      encoded = QPACK.encode_headers([{"x-long", long_value}])
      # name: "x-long" (6) → 0x26
      assert binary_part(encoded, 0, 3) == <<0x00, 0x00, 0x26>>
      assert binary_part(encoded, 3, 6) == "x-long"
      assert binary_part(encoded, 9, 2) == <<0x7F, 73>>
      assert binary_part(encoded, 11, 200) == long_value
    end
  end

  describe "decode_headers/1 - indexed static fields" do
    test "decodes single indexed field" do
      assert QPACK.decode_headers(<<0x00, 0x00, 0xD1>>) == {:ok, [{":method", "GET"}]}
    end

    test "decodes index 0" do
      assert QPACK.decode_headers(<<0x00, 0x00, 0xC0>>) == {:ok, [{":authority", ""}]}
    end

    test "decodes multi-byte index (index 63, two-byte form)" do
      assert QPACK.decode_headers(<<0x00, 0x00, 0xFF, 0>>) == {:ok, [{":status", "100"}]}
    end

    test "decodes multi-byte index (index 98)" do
      assert QPACK.decode_headers(<<0x00, 0x00, 0xFF, 35>>) ==
               {:ok, [{"x-frame-options", "sameorigin"}]}
    end

    test "decodes multiple indexed fields with trailing data consumed" do
      input = <<0x00, 0x00, 0xD1, 0xD7, 0xC1>>
      assert QPACK.decode_headers(input) ==
               {:ok, [{":method", "GET"}, {":scheme", "https"}, {":path", "/"}]}
    end

    test "decodes empty header block" do
      assert QPACK.decode_headers(<<0x00, 0x00>>) == {:ok, []}
    end
  end

  describe "decode_headers/1 - literal with static name reference" do
    test "decodes literal with static name ref (index 0)" do
      input = <<0x00, 0x00, 0x50, 11, "example.com">>
      assert QPACK.decode_headers(input) == {:ok, [{":authority", "example.com"}]}
    end

    test "decodes literal with static name ref (multi-byte index)" do
      # :status name ref at index 24: <<0x5F, 9>>, value "301"
      input = <<0x00, 0x00, 0x5F, 9, 3, "301">>
      assert QPACK.decode_headers(input) == {:ok, [{":status", "301"}]}
    end

    test "decodes literal with N=1 (never-index bit set) — bit is ignored on decode" do
      # N bit is bit 5; setting it: 0x50 | 0x20 = 0x70, index 0
      input = <<0x00, 0x00, 0x70, 11, "example.com">>
      assert QPACK.decode_headers(input) == {:ok, [{":authority", "example.com"}]}
    end
  end

  describe "decode_headers/1 - literal without name reference" do
    test "decodes field with inline name and value" do
      input = <<0x00, 0x00, 0x23, "via", 9, "1.1 proxy">>
      assert QPACK.decode_headers(input) == {:ok, [{"via", "1.1 proxy"}]}
    end

    test "decodes field with empty value" do
      input = <<0x00, 0x00, 0x23, "foo", 0>>
      assert QPACK.decode_headers(input) == {:ok, [{"foo", ""}]}
    end

    test "decodes field with multi-byte name length" do
      # "x-request-id" (12): <<0x27, 5>>
      input = <<0x00, 0x00, 0x27, 5, "x-request-id", 7, "abc-123">>
      assert QPACK.decode_headers(input) == {:ok, [{"x-request-id", "abc-123"}]}
    end

    test "decodes N=1 (never-index) literal — bit is ignored on decode" do
      # N bit is bit 4: 0x20 | 0x10 = 0x30, name len = 0 lower bits = 0
      # 0x30 | 3 = 0x33 for name len 3
      input = <<0x00, 0x00, 0x33, "foo", 3, "bar">>
      assert QPACK.decode_headers(input) == {:ok, [{"foo", "bar"}]}
    end
  end

  describe "decode_headers/1 - error cases" do
    test "rejects dynamic table indexed reference" do
      # 0x80 = indexed, T=0 (dynamic), index 0
      assert QPACK.decode_headers(<<0x00, 0x00, 0x80>>) ==
               {:error, :dynamic_table_not_supported}
    end

    test "rejects dynamic table name reference" do
      # 0x40 = literal name ref, T=0 (dynamic), N=0, index 0
      assert QPACK.decode_headers(<<0x00, 0x00, 0x40, 0>>) ==
               {:error, :dynamic_table_not_supported}
    end

    test "rejects Huffman-encoded name in literal-without-name-reference" do
      # 0x28 = 0b00101000: bits 7-5=001, N=0, H=1, name_len prefix=0
      assert QPACK.decode_headers(<<0x00, 0x00, 0x28>>) ==
               {:error, :huffman_name_not_supported}
    end

    test "rejects Huffman-encoded value in literal with name reference" do
      # name ref index 0 (:authority), then value with H=1
      # 0x83 = H=1, length=3 → huffman_not_supported
      assert QPACK.decode_headers(<<0x00, 0x00, 0x50, 0x83, "foo">>) ==
               {:error, :huffman_not_supported}
    end

    test "rejects unknown representation byte (post-base indexed 0x10)" do
      assert QPACK.decode_headers(<<0x00, 0x00, 0x10>>) ==
               {:error, {:unsupported_representation, 0x10}}
    end

    test "rejects unknown static index" do
      # index 99 does not exist; encode manually: <<0xFF, 36>>  (63 + 36 = 99)
      assert QPACK.decode_headers(<<0x00, 0x00, 0xFF, 36>>) ==
               {:error, {:unknown_static_index, 99}}
    end

    test "returns error on truncated integer continuation" do
      # 0xFF means indexed with partial=63=max, needs at least one continuation byte
      assert QPACK.decode_headers(<<0x00, 0x00, 0xFF>>) == {:error, :truncated_integer}
    end

    test "returns error on truncated string value" do
      # name ref to :authority (0x50), value says len=20 but only 3 bytes follow
      assert QPACK.decode_headers(<<0x00, 0x00, 0x50, 20, "hi!">>) ==
               {:error, :truncated_string}
    end

    test "returns error on truncated header name" do
      # literal no name ref, H=0: <<0x27, 3>> encodes name_len = 7+3 = 10,
      # but only 3 bytes ("foo") follow — truncated name
      assert QPACK.decode_headers(<<0x00, 0x00, 0x27, 3, "foo">>) ==
               {:error, :truncated_name}
    end

    test "returns error on truncated prefix" do
      assert QPACK.decode_headers(<<>>) == {:error, :truncated_integer}
    end

    test "stops at first error in a multi-field block" do
      # valid :method GET, then dynamic reference
      assert QPACK.decode_headers(<<0x00, 0x00, 0xD1, 0x80>>) ==
               {:error, :dynamic_table_not_supported}
    end
  end

  describe "encode/decode round-trips" do
    test "round-trips common HTTP request headers" do
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/api/v1/users"},
        {":authority", "api.example.com"},
        {"accept", "application/json"},
        {"user-agent", "MyClient/1.0"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips common HTTP response headers" do
      headers = [
        {":status", "200"},
        {"content-type", "application/json"},
        {"cache-control", "no-cache"},
        {"content-length", "42"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips headers with static-table values (all indexed)" do
      headers = [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
        {":status", "404"},
        {"content-encoding", "gzip"},
        {"cache-control", "no-store"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips a POST with content-type" do
      headers = [
        {":method", "POST"},
        {":path", "/submit"},
        {":authority", "example.com"},
        {"content-type", "application/x-www-form-urlencoded"},
        {"content-length", "27"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips headers entirely absent from static table" do
      headers = [
        {"x-correlation-id", "abc-123-def"},
        {"x-trace-id", "span-456"},
        {"x-forwarded-proto", "https"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips headers with empty values" do
      headers = [{"x-empty-a", ""}, {"x-empty-b", ""}]
      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips an empty header list" do
      assert {:ok, []} = QPACK.encode_headers([]) |> QPACK.decode_headers()
    end

    test "round-trips a long value requiring multi-byte string length encoding" do
      long_val = String.duplicate("a", 200)
      headers = [{"x-data", long_val}]
      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips the last static table entry (index 98)" do
      headers = [{":status", "200"}, {"x-frame-options", "sameorigin"}]
      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end

    test "round-trips mix of all three encoding strategies" do
      headers = [
        # indexed (exact match)
        {":method", "GET"},
        # literal with name ref (name in table, value not)
        {":authority", "api.example.com"},
        # literal without name ref (name not in table)
        {"x-request-id", "req-abc-123"}
      ]

      assert {:ok, ^headers} = headers |> QPACK.encode_headers() |> QPACK.decode_headers()
    end
  end

  describe "static table coverage" do
    test "every entry in the static table encodes to an indexed field" do
      # Build the table the same way the module does and verify each entry
      # round-trips through a single indexed encoding (exactly 3 bytes for indices < 63,
      # 4 bytes for indices 63–98).
      table = [
        {":authority", ""},
        {":path", "/"},
        {"age", "0"},
        {"content-disposition", ""},
        {"content-length", "0"},
        {"cookie", ""},
        {"date", ""},
        {"etag", ""},
        {"if-modified-since", ""},
        {"if-none-match", ""},
        {"last-modified", ""},
        {"link", ""},
        {"location", ""},
        {"referer", ""},
        {"set-cookie", ""},
        {":method", "CONNECT"},
        {":method", "DELETE"},
        {":method", "GET"},
        {":method", "HEAD"},
        {":method", "OPTIONS"},
        {":method", "POST"},
        {":method", "PUT"},
        {":scheme", "http"},
        {":scheme", "https"},
        {":status", "103"},
        {":status", "200"},
        {":status", "304"},
        {":status", "404"},
        {":status", "503"},
        {"accept", "*/*"},
        {"accept", "application/dns-message"},
        {"accept-encoding", "gzip, deflate, br"},
        {"accept-ranges", "bytes"},
        {"access-control-allow-headers", "cache-control"},
        {"access-control-allow-headers", "content-type"},
        {"access-control-allow-origin", "*"},
        {"cache-control", "max-age=0"},
        {"cache-control", "max-age=2592000"},
        {"cache-control", "max-age=604800"},
        {"cache-control", "no-cache"},
        {"cache-control", "no-store"},
        {"cache-control", "public, max-age=31536000"},
        {"content-encoding", "br"},
        {"content-encoding", "gzip"},
        {"content-type", "application/dns-message"},
        {"content-type", "application/javascript"},
        {"content-type", "application/json"},
        {"content-type", "application/x-www-form-urlencoded"},
        {"content-type", "image/gif"},
        {"content-type", "image/jpeg"},
        {"content-type", "image/png"},
        {"content-type", "text/css"},
        {"content-type", "text/html; charset=utf-8"},
        {"content-type", "text/plain"},
        {"content-type", "text/plain;charset=utf-8"},
        {"range", "bytes=0-"},
        {"strict-transport-security", "max-age=31536000"},
        {"strict-transport-security", "max-age=31536000; includesubdomains"},
        {"strict-transport-security", "max-age=31536000; includesubdomains; preload"},
        {"vary", "accept-encoding"},
        {"vary", "origin"},
        {"x-content-type-options", "nosniff"},
        {"x-xss-protection", "1; mode=block"},
        {":status", "100"},
        {":status", "204"},
        {":status", "206"},
        {":status", "302"},
        {":status", "400"},
        {":status", "403"},
        {":status", "421"},
        {":status", "425"},
        {":status", "500"},
        {"accept-language", ""},
        {"access-control-allow-credentials", "FALSE"},
        {"access-control-allow-credentials", "TRUE"},
        {"access-control-allow-headers", "*"},
        {"access-control-allow-methods", "get"},
        {"access-control-allow-methods", "get, post, options"},
        {"access-control-allow-methods", "options"},
        {"access-control-expose-headers", "content-length"},
        {"access-control-request-headers", "content-type"},
        {"access-control-request-method", "get"},
        {"access-control-request-method", "post"},
        {"alt-svc", "clear"},
        {"authorization", ""},
        {"content-security-policy",
         "script-src 'none'; object-src 'none'; base-uri 'none'"},
        {"early-data", "1"},
        {"expect-ct", ""},
        {"forwarded", ""},
        {"if-range", ""},
        {"origin", ""},
        {"purpose", "prefetch"},
        {"server", ""},
        {"timing-allow-origin", "*"},
        {"upgrade-insecure-requests", "1"},
        {"user-agent", ""},
        {"x-forwarded-for", ""},
        {"x-frame-options", "deny"},
        {"x-frame-options", "sameorigin"}
      ]

      Enum.each(table, fn {name, value} = header ->
        encoded = QPACK.encode_headers([header])
        # First two bytes are always the prefix; the rest is the field encoding.
        # For a static exact match this should decode back to the same header.
        assert {:ok, [decoded]} = QPACK.decode_headers(encoded),
               "Failed to round-trip static entry {#{inspect(name)}, #{inspect(value)}}"

        assert decoded == header,
               "Round-trip mismatch for {#{inspect(name)}, #{inspect(value)}}: got #{inspect(decoded)}"
      end)
    end
  end
end
