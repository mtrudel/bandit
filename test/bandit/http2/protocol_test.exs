defmodule HTTP2ProtocolTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  import Bitwise

  setup :https_server

  describe "frame splitting / merging" do
    test "it should handle cases where the request arrives in small chunks", context do
      socket = SimpleH2Client.tls_client(context)

      # Send connection preface, client settings & ping frame one byte at a time
      ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
         <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(2), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> :ssl.send(socket, byte) end)

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      socket = SimpleH2Client.tls_client(context)

      # Send connection preface, client settings & ping frame all in one
      :ssl.send(
        socket,
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
          <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>
      )

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "errors and unexpected frames" do
    @tag capture_log: true
    test "it should ignore unknown frame types", context do
      socket = SimpleH2Client.setup_connection(context)
      :ssl.send(socket, <<0, 0, 0, 254, 0, 0, 0, 0, 0>>)
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "it should shut down the connection gracefully when encountering a connection error",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      # Send a bogus SETTINGS frame
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 1>>)
      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "it should shut down the connection after read timeout has been reached with no initial data sent",
         context do
      socket = SimpleH2Client.tls_client(context)
      Process.sleep(1500)
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end

    @tag capture_log: true
    test "it should shut down the connection after read timeout has been reached with no data sent",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      Process.sleep(1500)
      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    @tag capture_log: true
    test "returns a connection error if too many requests are sent", context do
      context = https_server(context, http_2_options: [max_requests: 3])
      socket = SimpleH2Client.setup_connection(context)
      port = context[:port]

      {:ok, send_ctx} =
        SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", port)

      {:ok, 1, false, _, recv_ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      {:ok, send_ctx} =
        SimpleH2Client.send_simple_headers(socket, 3, :get, "/body_response", port, send_ctx)

      {:ok, 3, false, _, recv_ctx} = SimpleH2Client.recv_headers(socket, recv_ctx)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}

      {:ok, send_ctx} =
        SimpleH2Client.send_simple_headers(socket, 5, :get, "/body_response", port, send_ctx)

      {:ok, 5, false, _, _recv_ctx} = SimpleH2Client.recv_headers(socket, recv_ctx)
      assert SimpleH2Client.recv_body(socket) == {:ok, 5, true, "OK"}

      {:ok, _send_ctx} =
        SimpleH2Client.send_simple_headers(socket, 7, :get, "/body_response", port, send_ctx)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 5, 7}
    end
  end

  describe "settings exchange" do
    test "the server should send a SETTINGS frame at start of the connection", context do
      socket = SimpleH2Client.tls_client(context)
      :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
    end
  end

  describe "DATA frames" do
    test "sends end of stream when there is a single data frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def body_response(conn) do
      conn |> send_resp(200, "OK")
    end

    test "writes out a response with deflate encoding if so negotiated", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-encoding", "deflate"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      deflate_context = :zlib.open()
      :ok = :zlib.deflateInit(deflate_context)

      expected =
        deflate_context
        |> :zlib.deflate(String.duplicate("a", 10_000), :sync)
        |> IO.iodata_to_binary()

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    test "writes out a response with gzip encoding if so negotiated", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "gzip"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-encoding", "gzip"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      expected = :zlib.gzip(String.duplicate("a", 10_000))

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    test "writes out a response with x-gzip encoding if so negotiated", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "x-gzip"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-encoding", "gzip"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      expected = :zlib.gzip(String.duplicate("a", 10_000))

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    test "uses the first matching encoding in accept-encoding", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "foo, deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-encoding", "deflate"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      deflate_context = :zlib.open()
      :ok = :zlib.deflateInit(deflate_context)

      expected =
        deflate_context
        |> :zlib.deflate(String.duplicate("a", 10_000), :sync)
        |> IO.iodata_to_binary()

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    test "falls back to no encoding if no encodings provided", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    test "falls back to no encoding if no encodings match", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "a, b, c"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    def send_big_body(conn) do
      conn |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "sends multiple DATA frames with last one end of stream when chunking", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/chunk_response", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "OK"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "DOKEE"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    def chunk_response(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")
      |> elem(1)
      |> chunk("DOKEE")
      |> elem(1)
    end

    test "reads a zero byte body if none is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/echo", context.port)

      # A zero byte body being written will cause end_stream to be set on the header frame
      assert SimpleH2Client.successful_response?(socket, 1, true)
    end

    def echo(conn) do
      {:ok, body, conn} = read_body(conn)
      conn |> send_resp(200, body)
    end

    @tag capture_log: true
    test "rejects DATA frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 1, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    test "reads a one frame body if one frame is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "reads a multi frame body if many frames are sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, false, "OK")
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OKOK"}
    end

    # Success case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    test "reads a content-length with multiple content-lengths encoded body properly", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "POST"},
        {":path", "/expect_body_with_multiple_content_length"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"content-length", "8000,8000,8000"}
      ]

      SimpleH2Client.send_headers(socket, 1, false, headers)
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("a", 8_000))

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def expect_body_with_multiple_content_length(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000,8000,8000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000)
      send_resp(conn, 200, "OK")
    end

    # Error case for content-length as defined in https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3-2.5
    @tag capture_log: true
    test "returns a stream error if content length contains non-matching values", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "POST"},
        {":path", "/expect_body_with_multiple_content_length"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"content-length", "8000,8001,8000"}
      ]

      SimpleH2Client.send_headers(socket, 1, false, headers)
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("a", 8_000))

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if sent content-length is negative", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"content-length", "-321"}
      ]

      SimpleH2Client.send_headers(socket, 1, false, headers)
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("a", 8_000))

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if sent content length is non-integer", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"content-length", "foo"}
      ]

      SimpleH2Client.send_headers(socket, 1, false, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "returns a stream error if sent content-length doesn't match sent data", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"content-length", "3"}
      ]

      SimpleH2Client.send_headers(socket, 1, false, headers)
      SimpleH2Client.send_body(socket, 1, false, "OK")
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "rejects DATA frames received on a remote closed stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/sleep_and_echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 1}
    end

    def sleep_and_echo(conn) do
      {:ok, body, conn} = read_body(conn)
      Process.sleep(100)
      conn |> send_resp(200, body)
    end

    @tag capture_log: true
    test "rejects DATA frames received on a zero stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 0, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects DATA frames received on an invalid stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 2, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "HEADERS frames" do
    test "sends end of stream headers when there is no body", context do
      socket = SimpleH2Client.setup_connection(context)
      SimpleH2Client.send_simple_headers(socket, 1, :get, "/no_body_response", context.port)
      assert {:ok, 1, true, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
    end

    def no_body_response(conn) do
      conn |> send_resp(200, <<>>)
    end

    test "sends non-end of stream headers when there is a body", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)
      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert(SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"})
    end

    test "breaks large headers into multiple CONTINUATION frames when sending", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/large_headers", context.port)

      random_string = for _ <- 1..60_000, into: "", do: <<Enum.random(~c"0123456789abcdef")>>
      <<to_send::binary-size(16_384), rest::binary>> = random_string
      SimpleH2Client.send_body(socket, 1, false, to_send)

      <<to_send::binary-size(16_384), rest::binary>> = rest
      SimpleH2Client.send_body(socket, 1, false, to_send)

      <<to_send::binary-size(16_384), rest::binary>> = rest
      SimpleH2Client.send_body(socket, 1, false, to_send)
      SimpleH2Client.send_body(socket, 1, true, rest)

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      # We assume that 60k of random data will get hpacked down into somewhere
      # between 49152 and 65536 bytes, so we'll need 3 packets total
      {:ok, <<16_384::24, 1::8, 0::8, 0::1, 1::31>>} = :ssl.recv(socket, 9)
      {:ok, header_fragment} = :ssl.recv(socket, 16_384)

      {:ok, <<16_384::24, 9::8, 0::8, 0::1, 1::31>>} = :ssl.recv(socket, 9)
      {:ok, fragment_1} = :ssl.recv(socket, 16_384)

      {:ok, <<16_384::24, 9::8, 0::8, 0::1, 1::31>>} = :ssl.recv(socket, 9)
      {:ok, fragment_2} = :ssl.recv(socket, 16_384)

      {:ok, <<length::24, 9::8, 4::8, 0::1, 1::31>>} = :ssl.recv(socket, 9)
      {:ok, fragment_3} = :ssl.recv(socket, length)

      {:ok, headers, _ctx} =
        [header_fragment, fragment_1, fragment_2, fragment_3]
        |> IO.iodata_to_binary()
        |> HPAX.decode(HPAX.new(4096))

      assert [
               {":status", "200"},
               {"date", _date},
               {"cache-control", "max-age=0, private, must-revalidate"},
               {"giant", ^random_string}
             ] = headers

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      assert SimpleH2Client.connection_alive?(socket)
    end

    def large_headers(conn) do
      {:ok, body, conn} = read_body(conn)

      conn
      |> put_resp_header("giant", body)
      |> send_resp(200, "OK")
    end

    test "accepts well-formed headers without padding or priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send unadorned headers
      :ssl.send(socket, [<<0, 0, IO.iodata_length(headers), 1, 0x05, 0, 0, 0, 1>>, headers])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with priority
      :ssl.send(socket, [
        <<0, 0, IO.iodata_length(headers) + 5, 1, 0x25, 0, 0, 0, 1>>,
        <<0, 0, 0, 3, 5>>,
        headers
      ])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding
      :ssl.send(socket, [
        <<0, 0, IO.iodata_length(headers) + 5, 1, 0x0D, 0, 0, 0, 1>>,
        <<4>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding and priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding and priority
      :ssl.send(socket, [
        <<0, 0, IO.iodata_length(headers) + 10, 1, 0x2D, 0, 0, 0, 1>>,
        <<4, 0, 0, 0, 0, 1>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def headers_for_header_read_test(context) do
      headers = [
        {":method", "HEAD"},
        {":path", "/header_read_test"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"x-request-header", "Request"}
      ]

      ctx = HPAX.new(4096)
      {headers, _} = headers |> Enum.map(fn {k, v} -> {:store, k, v} end) |> HPAX.encode(ctx)
      IO.iodata_to_binary(headers)
    end

    def header_read_test(conn) do
      assert get_req_header(conn, "x-request-header") == ["Request"]

      conn |> send_resp(200, "OK")
    end

    test "accumulates header fragments over multiple CONTINUATION frames", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), header2::binary-size(20), header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, IO.iodata_length(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, [<<0, 0, IO.iodata_length(header2), 9, 0x00, 0, 0, 0, 1>>, header2])
      :ssl.send(socket, [<<0, 0, IO.iodata_length(header3), 9, 0x04, 0, 0, 0, 1>>, header3])

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "accepts HEADER frames sent as trailers", context do
      socket = SimpleH2Client.setup_connection(context)

      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, false, "OK")
      SimpleH2Client.send_headers(socket, 1, true, [{"x-trailer", "trailer"}], ctx)

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "rejects HEADER frames sent as trailers that contain pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, false, "OK")
      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end

    test "rejects HEADER frames which depend on itself", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding and priority
      :ssl.send(socket, [
        <<0, 0, IO.iodata_length(headers) + 5, 1, 0x25, 0, 0, 0, 1>>,
        <<0, 0, 0, 1, 5>>,
        headers
      ])

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "closes with an error when receiving a zero stream ID",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 0, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "closes with an error when receiving an even stream ID",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 2, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "closes with an error when receiving a stream ID we've already seen",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)
      assert {:ok, 99, true, _, _} = SimpleH2Client.recv_headers(socket)
      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 99, 1}
    end

    @tag capture_log: true
    test "closes with an error on a header frame with undecompressable header block", context do
      socket = SimpleH2Client.setup_connection(context)

      :ssl.send(socket, <<0, 0, 11, 1, 0x2C, 0, 0, 0, 1, 2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 9}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers with uppercase names", context do
      socket = SimpleH2Client.setup_connection(context)

      # Take example from H2Spec
      headers =
        <<130, 135, 68, 137, 98, 114, 209, 65, 226, 240, 123, 40, 147, 65, 139, 8, 157, 92, 11,
          129, 112, 220, 109, 199, 26, 127, 64, 6, 88, 45, 84, 69, 83, 84, 2, 111, 107>>

      :ssl.send(socket, [<<IO.iodata_length(headers)::24, 1::8, 5::8, 0::1, 1::31>>, headers])

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers with invalid pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {":bogus", "bogus"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers with response pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {":status", "200"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if pseudo headers appear after regular ones", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {"regular-header", "boring"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns an error if (almost) any hop-by-hop headers are present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"connection", "close"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "accepts TE header with a value of trailer", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/no_body_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"te", "trailers"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, true)
    end

    @tag capture_log: true
    test "returns an error if TE header is present with a value other than trailers", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"te", "trailers, deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if :method pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if multiple :method pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if :scheme pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if multiple :scheme pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if :path pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if multiple :path pseudo headers are received", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns a stream error if :path pseudo headers is empty", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", ""},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "combines Cookie headers per RFC9113§8.2.3", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/cookie_check"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"cookie", "a=b"},
        {"cookie", "c=d"},
        {"cookie", "e=f"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def cookie_check(conn) do
      assert get_req_header(conn, "cookie") == ["a=b; c=d; e=f"]

      conn |> send_resp(200, "OK")
    end

    test "breaks Cookie headers up per RFC9113§8.2.3", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/cookie_write_check"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"},
                {"cookie", "a=b"},
                {"cookie", "c=d"},
                {"cookie", "e=f"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def cookie_write_check(conn) do
      conn |> put_resp_header("cookie", "a=b; c=d; e=f") |> send_resp(200, "OK")
    end

    test "handles changes to client's header table size", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)

      {:ok, 1, false,
       [
         {":status", "200"},
         {"date", _date},
         {"cache-control", "max-age=0, private, must-revalidate"}
       ], ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      # Shrink our decoding table size
      SimpleH2Client.exchange_client_settings(socket, <<1::16, 1::32>>)

      ctx = HPAX.resize(ctx, 1)

      SimpleH2Client.send_simple_headers(socket, 3, :get, "/body_response", context.port)

      {:ok, 3, false,
       [
         {":status", "200"},
         {"date", _date},
         {"cache-control", "max-age=0, private, must-revalidate"}
       ], _ctx} = SimpleH2Client.recv_headers(socket, ctx)

      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers contain too many headers", context do
      context = https_server(context, http_2_options: [max_header_count: 40])
      socket = SimpleH2Client.setup_connection(context)

      headers =
        [
          {":method", "HEAD"},
          {":path", "/"},
          {":scheme", "https"},
          {":authority", "localhost:#{context[:port]}"}
        ] ++ for i <- 1..37, do: {"header#{i}", "foo"}

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 6}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers contain an overlong key", context do
      context = https_server(context, http_2_options: [max_header_key_length: 5000])
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context[:port]}"},
        {String.duplicate("a", 5_001), "foo"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 6}
    end

    @tag capture_log: true
    test "returns a stream error if sent headers contain an overlong value", context do
      context = https_server(context, http_2_options: [max_header_value_length: 5000])
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context[:port]}"},
        {"foo", String.duplicate("a", 5_001)}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 6}
    end
  end

  describe "PRIORITY frames" do
    test "receives PRIORITY frames without complaint (and does nothing)", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_priority(socket, 1, 3, 4)

      assert SimpleH2Client.connection_alive?(socket)
    end

    test "rejects PRIORITY frames which depend on itself", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_priority(socket, 1, 1, 4)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)
    end
  end

  describe "RST_STREAM frames" do
    @tag capture_log: true
    test "sends RST_FRAME with no error if stream task ends without closed stream", context do
      socket = SimpleH2Client.setup_connection(context)

      # Send headers with end_stream bit cleared
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/body_response", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 0}
      assert SimpleH2Client.connection_alive?(socket)
    end

    @tag capture_log: true
    test "sends RST_FRAME with error if stream task crashes", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/crasher", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 2}
      assert SimpleH2Client.connection_alive?(socket)
    end

    def crasher(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")

      raise "boom"
    end

    @tag capture_log: true
    test "rejects RST_STREAM frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_rst_stream(socket, 1, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    test "shuts down the stream task on receipt of an RST_STREAM frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/sleeper", context.port)
      SimpleH2Client.recv_headers(socket)
      {:ok, 1, false, "OK"} = SimpleH2Client.recv_body(socket)

      assert Process.whereis(:sleeper) |> Process.alive?()

      SimpleH2Client.send_rst_stream(socket, 1, 0)

      Process.sleep(100)

      assert Process.whereis(:sleeper) == nil
      assert SimpleH2Client.connection_alive?(socket)
    end

    def sleeper(conn) do
      Process.register(self(), :sleeper)

      conn
      |> send_chunked(200)
      |> chunk("OK")

      Process.sleep(:infinity)
    end
  end

  describe "SETTINGS frames" do
    test "the server should acknowledge a client's SETTINGS frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
    end
  end

  describe "PUSH_PROMISE frames" do
    @tag capture_log: true
    test "the server should reject any received PUSH_PROMISE frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 7, 5, 0, 0, 0, 0, 1, 0, 0, 0, 3, 1, 2, 3>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "PING frames" do
    test "the server should acknowledge a client's PING frames", context do
      socket = SimpleH2Client.setup_connection(context)
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "GOAWAY frames" do
    test "the server should send a GOAWAY frame when shutting down", context do
      socket = SimpleH2Client.setup_connection(context)

      assert SimpleH2Client.connection_alive?(socket)

      Process.sleep(100)

      ThousandIsland.stop(context.server_pid)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    test "the server should close the connection upon receipt of a GOAWAY frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_goaway(socket, 0, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    test "the server should return the last received stream id in the GOAWAY frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 99, :get, "/echo", context.port)
      SimpleH2Client.successful_response?(socket, 99, true)
      SimpleH2Client.send_goaway(socket, 0, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 99, 0}
    end
  end

  describe "WINDOW_UPDATE frames (upload direction)" do
    test "issues a large receive window update on first uploaded DATA frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "manages connection and stream receive windows separately", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert {:ok, 1, false, [{":status", "200"} | _], ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 3, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      # We should only see a stream update here
      {:ok, 3, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 3, false, ctx)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}
    end

    test "does not issue a subsequent update until receive window goes below 2^30", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/large_post", context.port)

      window = 65_535

      # Send a single byte to get the window moved up and ensure we see a window update
      SimpleH2Client.send_body(socket, 1, false, "a")
      window = window - 1

      {:ok, 0, adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^adjustment} = SimpleH2Client.recv_window_update(socket)

      window = window + adjustment
      assert window == (1 <<< 31) - 1

      # Send 2^16 - 1 chunks of 2^14 bytes to end up just shy of expecting a
      # window update (we expect one when our window goes below 2^30).
      iters = (1 <<< 16) - 1
      # Our duplicated string is 2^3 bytes long, so dupe is 2^11 times to get 2^14 bytes
      chunk = String.duplicate("01234567", 1 <<< 11)

      for _n <- 1..iters do
        SimpleH2Client.send_body(socket, 1, false, chunk)
      end

      # Adjust our window down for the frames we just sent
      window = window - iters * IO.iodata_length(chunk)

      assert window >= 1 <<< 30

      # Ensure we have not received a window update by pinging
      assert SimpleH2Client.connection_alive?(socket)

      # Now send one more chunk and update our window size
      SimpleH2Client.send_body(socket, 1, true, chunk)
      window = window - IO.iodata_length(chunk)

      # We should now be below 2^30 and so we expect an update
      assert window < 1 <<< 30
      {:ok, 0, adjustment} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, ^adjustment} = SimpleH2Client.recv_window_update(socket)
      window = window + adjustment
      assert window == (1 <<< 31) - 1

      assert SimpleH2Client.successful_response?(socket, 1, false)

      assert SimpleH2Client.recv_body(socket) ==
               {:ok, 1, true, "#{1 + (iters + 1) * IO.iodata_length(chunk)}"}
    end

    def large_post(conn) do
      do_large_post(conn, 0)
    end

    defp do_large_post(conn, size) do
      case read_body(conn) do
        {:ok, body, conn} -> conn |> send_resp(200, "#{size + IO.iodata_length(body)}")
        {:more, body, conn} -> do_large_post(conn, size + IO.iodata_length(body))
      end
    end
  end

  describe "WINDOW_UPDATE frames (download direction)" do
    test "respects the remaining space in the connection's send window", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      # Give ourselves lots of room on the stream
      SimpleH2Client.send_window_update(socket, 1, 1_000_000)

      SimpleH2Client.send_body(socket, 1, false, String.duplicate("a", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("b", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("c", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("d", 16_384))
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("e", 100))

      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 65_535 bytes as that is our initial connection window
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("b", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("c", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("d", 16_383)}

      # Grow the connection window by 100 and observe that we get 100 more bytes
      SimpleH2Client.send_window_update(socket, 0, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "d" <> String.duplicate("e", 99)}

      # Grow the connection window by another 100 and observe that we get the rest of the response
      # Also note that we receive end_of_stream here
      SimpleH2Client.send_window_update(socket, 0, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "e"}
    end

    test "respects the remaining space in the stream's send window", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      # Give ourselves lots of room on the connection
      SimpleH2Client.send_window_update(socket, 0, 1_000_000)

      SimpleH2Client.send_body(socket, 1, false, String.duplicate("a", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("b", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("c", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("d", 16_384))
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("e", 100))

      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 65_535 bytes as that is our initial stream window
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("b", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("c", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("d", 16_383)}

      # Grow the stream window by 100 and observe that we get 100 more bytes
      SimpleH2Client.send_window_update(socket, 1, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "d" <> String.duplicate("e", 99)}

      # Grow the stream window by another 100 and observe that we get the rest of the response
      # Also note that we receive end_of_stream here
      SimpleH2Client.send_window_update(socket, 1, 100)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "e"}
    end

    test "respects both stream and connection windows in complex scenarios", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 1, false, String.duplicate("a", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("b", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("c", 16_384))
      SimpleH2Client.send_body(socket, 1, false, String.duplicate("d", 16_384))
      SimpleH2Client.send_body(socket, 1, true, String.duplicate("e", 99))

      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      assert {:ok, 1, false, [{":status", "200"} | _], ctx} = SimpleH2Client.recv_headers(socket)

      # Expect 65_535 bytes as that is our initial connection window
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("b", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("c", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("d", 16_383)}

      # Start a second stream and observe that it gets blocked right away
      SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 3, false, String.duplicate("A", 16_384))
      SimpleH2Client.send_body(socket, 3, false, String.duplicate("B", 16_384))
      SimpleH2Client.send_body(socket, 3, false, String.duplicate("C", 16_384))
      SimpleH2Client.send_body(socket, 3, false, String.duplicate("D", 16_384))
      SimpleH2Client.send_body(socket, 3, true, String.duplicate("E", 99))

      assert {:ok, 3, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 3, false, ctx)

      # Grow the connection window by 65_535 and observe that we get bytes on 3
      # since 1 is blocked on its stream window
      SimpleH2Client.send_window_update(socket, 0, 65_535)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, String.duplicate("A", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, String.duplicate("B", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, String.duplicate("C", 16_384)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, String.duplicate("D", 16_383)}

      # Grow the stream windows such that we expect to see 100 bytes from 1 and 50 bytes from
      # 3 (note that 1 is queued at a higher priority than 3 due to FIFO ordering) Also note that
      # we receive end_of_stream on stream 1 here
      SimpleH2Client.send_window_update(socket, 3, 100)
      SimpleH2Client.send_window_update(socket, 1, 100)
      SimpleH2Client.send_window_update(socket, 0, 150)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "d" <> String.duplicate("e", 99)}
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, false, "D" <> String.duplicate("E", 49)}

      # Finally grow our connection window and verify we get the last of stream 3
      SimpleH2Client.send_window_update(socket, 0, 50)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, String.duplicate("E", 50)}
    end

    test "updates new stream send windows based on SETTINGS frames", context do
      socket = SimpleH2Client.setup_connection(context)

      # Give ourselves lots of room on the connection
      SimpleH2Client.send_window_update(socket, 0, 1_000_000)

      # Set our initial stream window size to something small
      SimpleH2Client.exchange_client_settings(socket, <<4::16, 100::32>>)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 1, true, String.duplicate("a", 16_384))

      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 100 bytes as that is our initial stream window
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 100)}

      # Grow the stream window by 100k and observe that we get everything else
      SimpleH2Client.send_window_update(socket, 1, 100_000)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 16_284)}
    end

    test "adjusts existing stream send windows based on SETTINGS frames", context do
      socket = SimpleH2Client.setup_connection(context)

      # Give ourselves lots of room on the connection
      SimpleH2Client.send_window_update(socket, 0, 1_000_000)

      # Set our initial stream window size to something small
      SimpleH2Client.exchange_client_settings(socket, <<4::16, 100::32>>)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)

      SimpleH2Client.send_body(socket, 1, true, String.duplicate("a", 16_384))

      assert {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      assert {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)
      assert SimpleH2Client.successful_response?(socket, 1, false)

      # Expect 100 bytes as that is our initial stream window
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 100)}

      # Shrink the window to 10 (this should give our open stream a window of -90)
      SimpleH2Client.exchange_client_settings(socket, <<4::16, 10::32>>)

      # Grow our window to 110 (this should give our open stream a window of 10)
      SimpleH2Client.exchange_client_settings(socket, <<4::16, 110::32>>)

      # We expect to see those 10 bytes come over
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, String.duplicate("a", 10)}

      # Finally, grow our window to 100k and observe the rest of our stream come over
      SimpleH2Client.exchange_client_settings(socket, <<4::16, 100_000::32>>)

      # We expect to see those 10 bytes come over
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 16_274)}
    end
  end

  describe "CONTINUATION frames" do
    @tag capture_log: true
    test "rejects non-CONTINUATION frames received when end_headers is false", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), _header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, IO.iodata_length(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects non-CONTINUATION frames received when from other streams", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, IO.iodata_length(header1), 1, 0x01, 0, 0, 0, 1>>, header1])
      :ssl.send(socket, [<<0, 0, IO.iodata_length(header2), 9, 0x00, 0, 0, 0, 2>>, header2])

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end

    @tag capture_log: true
    test "rejects CONTINUATION frames received when not expected", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = headers_for_header_read_test(context)

      :ssl.send(socket, [<<0, 0, IO.iodata_length(headers), 9, 0x04, 0, 0, 0, 1>>, headers])

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}
    end
  end

  describe "origin-form request target (no :authority header, RFC9113§8.3.1)" do
    test "derives scheme from :scheme pseudo header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["scheme"] == "https"
    end

    @tag capture_log: true
    test "resets stream if scheme does not match transport", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "http"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "derives host from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["host"] == "banana"
    end

    @tag capture_log: true
    test "resets stream if no host header set", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "derives port from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:1234"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["port"] == 1234
    end

    test "derives host from host header with ipv6 host", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["host"] == "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"
    end

    test "derives host and port from host header with ipv6 host", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "[::1]:1234"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["host"] == "[::1]"
      assert Jason.decode!(body)["port"] == 1234
    end

    @tag capture_log: true
    test "resets stream if port cannot be parsed from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:-1234"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "derives port from underlying transport if no port specified in host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["port"] == context.port
    end

    test "sets path and query string properly when no query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "sets path and query string properly when query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "ignores fragment when no query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components#nope"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "ignores fragment when query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b#nope"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "handles query strings with question mark characters in them", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b?c=d"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b?c=d"
    end

    def echo_components(conn) do
      send_resp(
        conn,
        200,
        conn |> Map.take([:scheme, :host, :port, :path_info, :query_string]) |> Jason.encode!()
      )
    end

    @tag capture_log: true
    test "returns stream error if a non-absolute path is send", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/../non_absolute_path"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns stream error if path has no leading slash", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "path_without_leading_slash"},
        {":scheme", "https"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end
  end

  describe "absolute-form request target (with :authority header, RFC9112§3.2.2)" do
    test "derives scheme from :scheme pseudo header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["scheme"] == "https"
    end

    @tag capture_log: true
    test "resets stream if scheme does not match transport", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "http"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    test "derives host from :authority header, even if it differs from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"},
        {"host", "orange:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["host"] == "banana"
    end

    test "derives ipv6 host from the URI, even if it differs from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]:#{context.port}"},
        {"host", "orange"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["host"] == "[FEDC:BA98:7654:3210:FEDC:BA98:7654:3210]"
    end

    test "derives port from host header, even if it differs from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "banana:1234"},
        {"host", "banana:2345"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["port"] == 1234
    end

    test "derives port from underlying transport if no port specified in host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "banana"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["port"] == context.port
    end

    test "sets path and query string properly when no query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "sets path and query string properly when query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "ignores fragment when no query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components#nope"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == ""
    end

    test "ignores fragment when query string is present", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b#nope"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b"
    end

    test "handles query strings with question mark characters in them", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components?a=b?c=d"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["echo_components"]
      assert Jason.decode!(body)["query_string"] == "a=b?c=d"
    end

    @tag capture_log: true
    test "returns stream error if a non-absolute path is send", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/../non_absolute_path"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end

    @tag capture_log: true
    test "returns stream error if path has no leading slash", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "path_without_leading_slash"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
    end
  end

  describe "asterisk-form request target (RFC9113§8.3.1 & RFC9112§3.2.4)" do
    @tag capture_log: true
    test "parse global OPTIONS path correctly", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "OPTIONS"},
        {":path", "*"},
        {":scheme", "https"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["path_info"] == ["*"]
    end

    def unquote(:*)(conn) do
      echo_components(conn)
    end
  end
end
