defmodule CompressionNegotiationTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  alias Bandit.Compression

  # The Accept-Encoding values that Bandit.Compression resolves without parsing. Each is also
  # tried in two spellings the general parser handles instead: upcased (codings are matched case
  # insensitively) and with a trailing space (which the list parser strips). The fast path must
  # agree with the general parser on every one of them
  @common_values [
    "gzip, deflate, br, zstd",
    "gzip, deflate, br",
    "gzip, deflate",
    "deflate, gzip, br, zstd",
    "gzip"
  ]

  # zstd is in the default response encodings only when the :zstd module is available (OTP 28+)
  @default_encodings if Code.ensure_loaded?(:zstd),
                       do: ~w(zstd gzip x-gzip deflate),
                       else: ~w(gzip x-gzip deflate)

  describe "negotiate_content_encodings/2 for common Accept-Encoding values" do
    for value <- @common_values do
      test "agrees with the general parser for #{inspect(value)}" do
        value = unquote(value)
        result = Compression.negotiate_content_encodings(value, [])

        assert result == Compression.negotiate_content_encodings(String.upcase(value), [])
        assert result == Compression.negotiate_content_encodings(value <> " ", [])
      end
    end

    test "returns the default encodings the client accepts, in Bandit's preference order" do
      accepting_zstd = Enum.filter(@default_encodings, &(&1 in ~w(zstd gzip deflate)))

      assert Compression.negotiate_content_encodings("gzip, deflate, br, zstd", []) ==
               accepting_zstd

      assert Compression.negotiate_content_encodings("deflate, gzip, br, zstd", []) ==
               accepting_zstd

      assert Compression.negotiate_content_encodings("gzip, deflate, br", []) == ~w(gzip deflate)
      assert Compression.negotiate_content_encodings("gzip, deflate", []) == ~w(gzip deflate)
      assert Compression.negotiate_content_encodings("gzip", []) == ~w(gzip)
    end

    test "honors configured response_encodings" do
      opts = [response_encodings: ~w(deflate gzip)]

      assert Compression.negotiate_content_encodings("gzip, deflate, br, zstd", opts) ==
               ~w(deflate gzip)

      assert Compression.negotiate_content_encodings("gzip", response_encodings: ~w(deflate)) ==
               []
    end

    test "returns no encodings when compression is disabled" do
      assert Compression.negotiate_content_encodings("gzip, deflate, br, zstd", compress: false) ==
               []
    end

    test "still parses values it does not recognize" do
      assert Compression.negotiate_content_encodings("gzip;q=0, deflate", []) == ~w(deflate)
      assert Compression.negotiate_content_encodings("GZIP, deflate", []) == ~w(gzip deflate)
      assert Compression.negotiate_content_encodings("gzip,deflate", []) == ~w(gzip deflate)
      assert Compression.negotiate_content_encodings("br", []) == []
    end
  end

  describe "over HTTP/1" do
    setup :http_server
    setup :req_http1_client

    test "compresses a response with a browser's Accept-Encoding", context do
      response =
        Req.get!(context.req,
          url: "/send_big_body",
          headers: [{"accept-encoding", "gzip, deflate, br, zstd"}]
        )

      expected_encoding = if Code.ensure_loaded?(:zstd), do: "zstd", else: "gzip"

      assert response.status == 200
      assert response.headers["content-encoding"] == [expected_encoding]
      assert response.headers["vary"] == ["accept-encoding"]
    end

    test "compresses a response with a bare gzip Accept-Encoding", context do
      response =
        Req.get!(context.req, url: "/send_big_body", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert response.headers["content-encoding"] == ["gzip"]
      assert response.body == :zlib.gzip(String.duplicate("a", 10_000))
    end

    def send_big_body(conn) do
      send_resp(conn, 200, String.duplicate("a", 10_000))
    end
  end
end
