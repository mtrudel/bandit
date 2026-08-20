defmodule CompressionTest do
  use ExUnit.Case, async: true

  alias Bandit.Compression

  describe "negotiate_content_encoding/2" do
    # The default response_encodings list is platform dependent (zstd is included when the
    # :zstd module is available), so tests which exercise the wildcard pin an explicit
    # preference order to stay deterministic across OTP versions
    @encodings ~w(gzip x-gzip deflate)

    defp negotiate(accept_encoding, opts \\ []),
      do: Compression.negotiate_content_encoding(accept_encoding, opts)

    test "returns nil when no accept-encoding header is present" do
      assert negotiate(nil) == nil
    end

    test "selects a plainly listed encoding in server preference order" do
      assert negotiate("gzip, deflate") == "gzip"
      assert negotiate("deflate, gzip") == "gzip"
      assert negotiate("deflate") == "deflate"
    end

    test "compares codings case-insensitively (RFC9110§8.4.1)" do
      assert negotiate("GZIP") == "gzip"
      assert negotiate("Deflate") == "deflate"
    end

    test "honors q-values on listed encodings (any q>0 is acceptable)" do
      assert negotiate("gzip;q=1.0") == "gzip"
      assert negotiate("gzip;q=0.5") == "gzip"
      assert negotiate("br;q=1.0, gzip;q=0.5") == "gzip"
    end

    test "treats q=0 as a refusal" do
      assert negotiate("gzip;q=0, deflate") == "deflate"
      assert negotiate("gzip;q=0") == nil
      assert negotiate("gzip;q=0.0, deflate;q=0.000") |> is_nil()
    end

    test "honors the '*' wildcard" do
      assert negotiate("*", response_encodings: @encodings) == "gzip"
      assert negotiate("*;q=0, deflate", response_encodings: @encodings) == "deflate"
      assert negotiate("*;q=0", response_encodings: @encodings) == nil
    end

    test "tolerates optional whitespace and mixed case around the q parameter" do
      assert negotiate("gzip ; q=0.8") == "gzip"
      assert negotiate("gzip; Q=0") |> is_nil()
    end

    test "reads malformed q values leniently as acceptance" do
      assert negotiate("gzip;q=abc") == "gzip"
      assert negotiate("gzip;q=") == "gzip"
    end

    test "does not compress when only identity is acceptable" do
      assert negotiate("identity") == nil
      assert negotiate("identity;q=1.0, *;q=0", response_encodings: @encodings) == nil
      assert negotiate("identity;q=0, gzip") == "gzip"
    end

    test "returns nil when compression is disabled" do
      assert negotiate("gzip", compress: false) == nil
    end

    test "respects a configured response_encodings preference order" do
      assert negotiate("gzip, deflate", response_encodings: ["deflate", "gzip"]) == "deflate"
    end
  end
end
