defmodule CompressionTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  alias Bandit.Compression

  # An adapter for a client that accepts gzip, with the given http options
  defp adapter(http_opts \\ [], content_encodings \\ ["gzip"]) do
    %Bandit.Adapter{content_encodings: content_encodings, opts: %{http: http_opts, websocket: []}}
  end

  # Releases the compressor a compressed context holds
  defp finish({_headers, %Compression{method: :identity}}), do: :ok
  defp finish({_headers, context}), do: Compression.close(context, [])

  defp method({_headers, %Compression{method: method}}), do: method

  describe "compress_threshold" do
    test "does not compress a body shorter than the threshold" do
      result = Compression.new(adapter(), 200, [{"content-type", "text/plain"}], 299)

      assert method(result) == :identity
      assert {headers, _context} = result
      assert Bandit.Headers.get_header(headers, "content-encoding") == nil
      # The response still varies on accept-encoding, as a longer body would be compressed
      assert Bandit.Headers.get_header(headers, "vary") == "accept-encoding"
    end

    test "compresses a body at least as long as the threshold" do
      result = Compression.new(adapter(), 200, [{"content-type", "text/plain"}], 300)

      assert method(result) == :gzip
      assert {headers, _context} = result
      assert Bandit.Headers.get_header(headers, "content-encoding") == "gzip"
      finish(result)
    end

    test "honours a configured threshold" do
      http_opts = [compress_threshold: 10]

      assert Compression.new(adapter(http_opts), 200, [], 9) |> method() == :identity

      result = Compression.new(adapter(http_opts), 200, [], 10)
      assert method(result) == :gzip
      finish(result)
    end

    test "never compresses an empty body, whatever the threshold" do
      assert Compression.new(adapter(compress_threshold: 0), 200, [], 0) |> method() == :identity

      result = Compression.new(adapter(compress_threshold: 0), 200, [], 1)
      assert method(result) == :gzip
      finish(result)
    end

    test "does not apply to a streamed response, whose length is not known" do
      result = Compression.new(adapter([], ["deflate"]), 200, [], nil, true)

      assert method(result) == :deflate
      finish(result)
    end
  end

  describe "incompressible_content_types" do
    test "does not compress content types which are already compressed" do
      for content_type <- [
            "image/png",
            "image/jpeg",
            "video/mp4",
            "audio/mpeg",
            "font/woff2",
            "application/zip",
            "application/octet-stream"
          ] do
        result = Compression.new(adapter(), 200, [{"content-type", content_type}], 10_000)
        assert method(result) == :identity, "expected #{content_type} not to be compressed"
        assert {headers, _context} = result
        assert Bandit.Headers.get_header(headers, "content-encoding") == nil
      end
    end

    test "matches the media type without its parameters and without regard to case" do
      for content_type <- ["image/png; charset=utf-8", "IMAGE/PNG", "Video/MP4; codecs=\"avc1\""] do
        result = Compression.new(adapter(), 200, [{"content-type", content_type}], 10_000)
        assert method(result) == :identity, "expected #{content_type} not to be compressed"
      end
    end

    test "compresses other content types, and responses with no content type" do
      for headers <- [
            [{"content-type", "text/html; charset=utf-8"}],
            [{"content-type", "application/json"}],
            [{"content-type", "image/svg+xml"}],
            []
          ] do
        result = Compression.new(adapter(), 200, headers, 10_000)
        assert method(result) == :gzip, "expected #{inspect(headers)} to be compressed"
        finish(result)
      end
    end

    test "honours a configured list" do
      http_opts = [incompressible_content_types: ["text/csv"]]

      assert Compression.new(adapter(http_opts), 200, [{"content-type", "text/csv"}], 10_000)
             |> method() == :identity

      result = Compression.new(adapter(http_opts), 200, [{"content-type", "image/png"}], 10_000)
      assert method(result) == :gzip
      finish(result)

      result =
        Compression.new(
          adapter(incompressible_content_types: []),
          200,
          [{"content-type", "image/png"}],
          10_000
        )

      assert method(result) == :gzip
      finish(result)
    end
  end

  describe "over HTTP/1" do
    setup :http_server
    setup :req_http1_client

    test "sends a body shorter than the threshold as it is", context do
      response =
        Req.get!(context.req, url: "/send_small_body", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert response.headers["content-encoding"] == nil
      assert response.headers["content-length"] == ["2"]
      assert response.headers["vary"] == ["accept-encoding"]
      assert response.body == "OK"
    end

    test "compresses a body as long as the threshold", context do
      response =
        Req.get!(context.req,
          url: "/send_threshold_body",
          headers: [{"accept-encoding", "gzip"}]
        )

      assert response.status == 200
      assert response.headers["content-encoding"] == ["gzip"]
      assert response.body == :zlib.gzip(String.duplicate("a", 300))
    end

    test "honours a configured threshold", context do
      context =
        context
        |> http_server(http_options: [compress_threshold: 2])
        |> Enum.into(context)

      response =
        Req.get!(context.req,
          url: "/send_small_body",
          base_url: context.base,
          headers: [{"accept-encoding", "gzip"}]
        )

      assert response.status == 200
      assert response.headers["content-encoding"] == ["gzip"]
      assert response.body == :zlib.gzip("OK")
    end

    test "sends an image as it is", context do
      response = Req.get!(context.req, url: "/send_png", headers: [{"accept-encoding", "gzip"}])

      assert response.status == 200
      assert response.headers["content-encoding"] == nil
      assert response.headers["content-length"] == ["10000"]
      assert response.headers["content-type"] == ["image/png"]
    end

    def send_small_body(conn), do: send_resp(conn, 200, "OK")

    def send_threshold_body(conn), do: send_resp(conn, 200, String.duplicate("a", 300))

    def send_png(conn) do
      conn
      |> put_resp_content_type("image/png", nil)
      |> send_resp(200, String.duplicate("a", 10_000))
    end
  end
end
