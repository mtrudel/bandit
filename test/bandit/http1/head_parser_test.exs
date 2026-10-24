defmodule HTTP1HeadParserTest do
  # Differential tests: reading a request head with Bandit.HTTP1.HeadParser in
  # front must give exactly what the decode_packet loop alone gives, for every
  # input and however it is split across reads. Both paths run through
  # Bandit.HTTP1.Socket's real code, reading from a transport that hands out
  # prepared chunks.
  use ExUnit.Case, async: true

  alias Bandit.HTTP1.HeadParser
  alias Bandit.HTTPTransport.Bandit.HTTP1.Socket, as: Impl

  # Hands out the chunks queued in the reading process's dictionary, then
  # times out, as a quiet client would.
  defmodule ChunkTransport do
    @moduledoc false
    def recv(:chunks, _length, _timeout) do
      case Process.get(:chunks, []) do
        [chunk | rest] ->
          Process.put(:chunks, rest)
          {:ok, chunk}

        [] ->
          {:error, :timeout}
      end
    end
  end

  @limits {10_000, 10_000, 50}

  defp opts({max_line, max_header, max_count}),
    do: [
      max_request_line_length: max_line,
      max_header_length: max_header,
      max_header_count: max_count
    ]

  # What reading the head from these chunks comes to: the parsed head and
  # socket state, or the error raised, plus whatever was left unread.
  defp outcome(fun, [first | rest], limits) do
    span = ThousandIsland.Telemetry.start_span(:connection, %{}, %{handler: __MODULE__})

    ti_socket = %ThousandIsland.Socket{
      socket: :chunks,
      transport_module: ChunkTransport,
      read_timeout: 100,
      handshake_timeout: 100,
      silent_terminate_on_error: false,
      span: span,
      peername: nil
    }

    socket = %Bandit.HTTP1.Socket{
      socket: ti_socket,
      buffer: first,
      opts: %{http_1: opts(limits)}
    }

    Process.put(:chunks, rest)

    result =
      try do
        {method, target, headers, socket} = fun.(socket)
        {:ok, method, target, headers, socket.version, socket.read_state, socket.buffer}
      rescue
        e -> {:raised, e.__struct__, Exception.message(e)}
      end

    {result, Process.delete(:chunks)}
  end

  defp assert_same(chunks, limits \\ @limits) do
    assert outcome(&Impl.read_head!/1, chunks, limits) ==
             outcome(&Impl.read_head_decode_packet!/1, chunks, limits),
           "mismatch for #{inspect(chunks)}"
  end

  # Whole, and split in two at every offset.
  defp assert_same_split(bin, limits \\ @limits) do
    assert_same([bin], limits)

    for i <- 0..byte_size(bin) do
      <<a::binary-size(^i), b::binary>> = bin
      assert_same([a, b], limits)
    end
  end

  test "known headers come out lowercase in every recognised spelling" do
    for name <- HeadParser.known_headers(),
        raw <- [
          name,
          String.upcase(name),
          name |> String.split("-") |> Enum.map_join("-", &String.capitalize/1)
        ] do
      req = "GET / HTTP/1.1\r\n#{raw}: v\r\n\r\n"
      assert {:ok, _, [{^name, "v"}], ""} = HeadParser.parse(req, @limits)
      assert_same([req])
    end
  end

  for {name, req} <- HTTP1HeadCorpus.requests() do
    test "corpus #{name} takes the fast path and matches decode_packet" do
      req = unquote(req)

      assert {:ok, {_, {nil, nil, nil, "/" <> _}, :"HTTP/1.1"}, _, ""} =
               HeadParser.parse(req, @limits)

      assert_same([req <> "trailing body bytes"])
      assert_same_split(req)
    end
  end

  test "header name lowercasing" do
    for name <-
          ~w(host HOST Host hOST content-md5 CONTENT-LENGTH x-foo-bar X-FOO-BAR x_foo -foo --foo
             a--b x-1a 1abc aBC-dEF set-cookie2 www-authenticate x!#$%&'*+.^_`|~ Sec-Websocket-Key) do
      req = "GET / HTTP/1.1\r\n#{name}: v\r\n\r\n"
      lower = String.downcase(name)
      assert {:ok, _, [{^lower, "v"}], ""} = HeadParser.parse(req, @limits)
      assert_same([req])
    end
  end

  test "values" do
    for value <- [
          "",
          " ",
          "\t",
          "  lead",
          "trail  ",
          "a\tb \t",
          <<0, 128, 255>>,
          "a:b: c",
          <<0x7F>>
        ] do
      assert_same(["GET / HTTP/1.1\r\nFoo:#{value}\r\n\r\n"])
      assert_same(["GET / HTTP/1.1\r\nFoo: #{value}\r\n\r\n"])
    end
  end

  test "request lines" do
    for line <- [
          "GET / HTTP/1.1",
          "GET / HTTP/1.0",
          "GET / HTTP/0.9",
          "GET / HTTP/2.0",
          "GET / http/1.1",
          "GET /",
          "get / HTTP/1.1",
          "PATCH /x HTTP/1.1",
          "PROPFIND /x HTTP/1.1",
          "GET  / HTTP/1.1",
          "GET / HTTP/1.1 ",
          "GET http://example.com/a?b HTTP/1.1",
          "GET http://example.com:8080/a HTTP/1.1",
          "OPTIONS * HTTP/1.1",
          "GET * HTTP/1.1",
          "CONNECT example.com:443 HTTP/1.1",
          "GET example.com HTTP/1.1",
          "GET /a\tb HTTP/1.1",
          "GET /a" <> <<0x7F>> <> " HTTP/1.1",
          "GET /a" <> <<0x80>> <> " HTTP/1.1",
          "GET /?a=b#c HTTP/1.1"
        ] do
      assert_same_split("#{line}\r\nhost: x\r\n\r\n")
      assert_same_split("#{line}\nhost: x\n\n")
    end
  end

  test "leading empty lines, LF-only endings, obs-fold and junk" do
    for req <- [
          "\r\nGET / HTTP/1.1\r\nhost: x\r\n\r\n",
          "\r\n\r\nGET / HTTP/1.1\r\nhost: x\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\r\n folded\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\r\n\tfolded\r\n\r\n",
          "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n",
          "GET / HTTP/1.1\r\nHost : x\r\n\r\n",
          "GET / HTTP/1.1\r\n: x\r\n\r\n",
          "GET / HTTP/1.1\r\nHo\x01st: x\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\rfoo\r\n\r\n",
          "GET / HTTP/1.1\nhost: x\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\ncontent-length: 5\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\r\ntransfer\x7Fencoding: chunked\r\n\r\n",
          "HTTP/1.1 200 OK\r\n\r\n"
        ] do
      assert_same_split(req)
    end
  end

  @boundary_bytes [0, ?\t, ?\n, ?\r, 0x1F, ?\s, ?!, ?a, 0x7E, 0x7F, 0x80, 0xFF]

  test "every interesting byte at every offset of a value and a target (SWAR edges)" do
    for len <- 0..20, i <- 0..max(len - 1, 0), b <- @boundary_bytes do
      chunk = String.duplicate("a", len)
      chunk = if len == 0, do: chunk, else: put_byte(chunk, i, b)
      assert_same(["GET / HTTP/1.1\r\nFoo: #{chunk}\r\nBar: x\r\n\r\n"])
      assert_same(["GET /#{chunk} HTTP/1.1\r\nFoo: x\r\n\r\n"])
    end
  end

  test "line length limits at and around the boundary" do
    for max <- 20..60, len <- 0..60 do
      target = "/" <> String.duplicate("a", len)
      value = String.duplicate("v", len)
      limits = {max, max, 50}
      req = "GET #{target} HTTP/1.1\r\nfoo: #{value}\r\n\r\n"
      assert_same([req], limits)
      assert_same([binary_part(req, 0, byte_size(req) - 2)], limits)
      assert_same(["GET / HTTP/1.1\r\nfoo: #{value}"], limits)
    end
  end

  test "header count limit" do
    for max <- 0..6, n <- 0..8 do
      headers = Enum.map_join(1..n//1, fn i -> "h#{i}: v\r\n" end)
      assert_same_split("GET / HTTP/1.1\r\n#{headers}\r\n", {10_000, 10_000, max})
    end
  end

  test "requests sent one byte per read" do
    reqs =
      Map.values(HTTP1HeadCorpus.requests()) ++
        [
          "GET / HTTP/1.1\nhost: x\n\n",
          "GET / HTTP/1.1\r\nhost: x\r\n\n",
          "GET / HTTP/1.1\r\nhost: x\r\n folded\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\rfoo\r\n\r\n",
          "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n",
          "GET / HTTP/1.1\r\nhost: x\r\n\r\nGET / HTTP/1.1\r\n\r\n"
        ]

    for req <- reqs do
      assert_same(for <<b <- req>>, do: <<b>>)
    end
  end

  test "partial lines sent one byte per read, at and around the limits" do
    for max <- 20..40, len <- 0..40 do
      limits = {max, max, 50}
      value = String.duplicate("v", len)
      target = "/" <> String.duplicate("a", len)

      for req <- ["GET / HTTP/1.1\r\nfoo: #{value}", "GET #{target}"] do
        assert_same(for(<<b <- req>>, do: <<b>>), limits)
      end
    end
  end

  test "randomly mutated corpus requests" do
    :rand.seed(:exsss, {1, 2, 3})
    reqs = Map.values(HTTP1HeadCorpus.requests())
    bytes = @boundary_bytes ++ ~c":/ ?#-AZaz09"

    for _ <- 1..3_000 do
      req = Enum.random(reqs)
      i = :rand.uniform(byte_size(req)) - 1
      req = put_byte(req, i, Enum.random(bytes))
      cut = :rand.uniform(byte_size(req) + 1) - 1
      <<a::binary-size(^cut), b::binary>> = req
      assert_same([req])
      assert_same([a, b])
    end
  end

  defp put_byte(bin, i, b) do
    <<pre::binary-size(^i), _, post::binary>> = bin
    <<pre::binary, b, post::binary>>
  end
end
