defmodule HTTP1PlainHeadersTest do
  # Bandit.HTTP1.Socket reads plain header lines in a single pass of its own, and leaves every
  # other line to :erlang.decode_packet/3. A head which arrives one byte per read never has a whole
  # line (and the byte after it) in the buffer when that pass runs, so each of its lines is read by
  # decode_packet. The two must agree, so these tests read every head both ways and compare
  use ExUnit.Case, async: true

  defmodule ChunkTransport do
    @moduledoc false
    def recv(:chunks, _length, _timeout) do
      case Process.get(:chunks, []) do
        [chunk | rest] ->
          Process.put(:chunks, rest)
          {:ok, chunk}

        [] ->
          {:error, :closed}
      end
    end
  end

  @head "GET /a?b=c HTTP/1.1\r\n" <>
          "Host: example.com\r\n" <>
          "sec-ch-ua: \"Chromium\";v=\"142\"\r\n" <>
          "X-Request-ID: 4bf92f35\r\n" <>
          "Accept: text/html, */*;q=0.8 \t\r\n" <>
          "Cookie:a=b; c=d\r\n" <>
          "Content-Length: 5\r\n\r\nhello"

  # Lines which the single pass must leave alone, and a few which it reads in less usual ways
  @lines [
    "X-Folded: a\r\n b",
    "X-Folded: a\r\n\tb",
    "X-Bare-LF: a\nX-Next: b",
    "X-Bare-CR: a\rb",
    "X-Space-Before-Colon : a",
    "no colon here",
    ": no name",
    "X-NUL: a\0b",
    "X-DEL: a\x7Fb",
    "X-Obs-Text: caf\xE9",
    "X(Not-A-Token): a",
    "X-Empty:",
    "X-Only-Whitespace: \t \t",
    "COOKIE: upper",
    "cOOKIE: mixed",
    "Content-Length: 5",
    String.duplicate("X-Long-Name-", 6) <> ": a",
    "X-Colons: a:b: c"
  ]

  defp read(chunks, http_1_opts) do
    [buffer | chunks] = chunks
    Process.put(:chunks, chunks)

    transport = %ThousandIsland.Socket{
      socket: :chunks,
      transport_module: ChunkTransport,
      read_timeout: 100,
      handshake_timeout: 100,
      silent_terminate_on_error: false,
      span: ThousandIsland.Telemetry.start_span(:connection, %{}, %{handler: __MODULE__}),
      peername: nil
    }

    socket = %Bandit.HTTP1.Socket{socket: transport, buffer: buffer, opts: %{http_1: http_1_opts}}

    try do
      {:ok, method, target, headers, socket} = Bandit.HTTPTransport.read_headers(socket)
      unread = IO.iodata_to_binary([socket.buffer | Process.get(:chunks)])
      {:ok, method, target, headers, socket.request_connection_header, unread}
    rescue
      error in [Bandit.HTTPError, Bandit.TransportError] ->
        {:error, error.__struct__, Exception.message(error), Map.get(error, :plug_status)}
    end
  end

  defp read_whole(head, opts \\ []), do: read([head], opts)
  defp read_bytes(head, opts \\ []), do: read(for(<<byte <- head>>, do: <<byte>>), opts)

  defp with_line(line), do: String.replace(@head, "Cookie:a=b; c=d", line)

  test "reads plain lines as decode_packet does" do
    expected =
      {:ok, "GET", {nil, nil, nil, "/a?b=c"},
       [
         {"host", "example.com"},
         {"sec-ch-ua", ~s("Chromium";v="142")},
         {"x-request-id", "4bf92f35"},
         {"accept", "text/html, */*;q=0.8"},
         {"cookie", "a=b; c=d"},
         {"content-length", "5"}
       ], nil, "hello"}

    assert read_whole(@head) == expected
    assert read_bytes(@head) == expected
  end

  test "reads other lines as decode_packet does" do
    for line <- @lines do
      head = with_line(line)
      assert read_whole(head) == read_bytes(head), "differs for #{inspect(line)}"
    end
  end

  test "applies the header limits as decode_packet does" do
    for max <- [24, 40], length <- (max - 3)..(max + 3), name <- ["Cookie", "x-len"] do
      head = with_line(name <> ": " <> String.duplicate("v", length - byte_size(name) - 4))
      opts = [max_header_length: max]
      assert read_whole(head, opts) == read_bytes(head, opts), "differs at #{length} of #{max}"
    end

    for max <- 4..7 do
      opts = [max_header_count: max]
      assert read_whole(@head, opts) == read_bytes(@head, opts), "differs at 6 of #{max}"
    end
  end

  test "reads randomly damaged heads as decode_packet does" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..2_000 do
      head = Enum.reduce(1..:rand.uniform(3), @head, fn _, head -> damage(head) end)
      assert read_whole(head) == read_bytes(head), "differs for #{inspect(head)}"
    end
  end

  @bytes [0, ?\t, ?\n, ?\r, ?\s, ?:, ?A, ?z, ?-, ?(, 127, 128, 255]

  # Inserts, replaces or removes one byte
  defp damage(head) do
    at = :rand.uniform(byte_size(head)) - 1
    before = binary_part(head, 0, at)
    <<byte, rest::binary>> = binary_part(head, at, byte_size(head) - at)

    case :rand.uniform(3) do
      1 -> before <> <<Enum.random(@bytes), byte>> <> rest
      2 -> before <> <<Enum.random(@bytes)>> <> rest
      3 -> before <> rest
    end
  end
end
