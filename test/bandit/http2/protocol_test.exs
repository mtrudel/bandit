defmodule HTTP2ProtocolTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  import Bitwise
  alias Bandit.Util

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
      |> Enum.each(fn byte -> Transport.send(socket, byte) end)

      assert {:ok, :settings, 0, 0, <<>>} == SimpleH2Client.recv_frame(socket)
      assert {:ok, :settings, 1, 0, <<>>} == SimpleH2Client.recv_frame(socket)
      assert {:ok, :ping, 1, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>} == SimpleH2Client.recv_frame(socket)
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      socket = SimpleH2Client.tls_client(context)

      # Send connection preface, client settings & ping frame all in one
      Transport.send(
        socket,
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
          <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>
      )

      assert {:ok, :settings, 0, 0, <<>>} == SimpleH2Client.recv_frame(socket)
      assert {:ok, :settings, 1, 0, <<>>} == SimpleH2Client.recv_frame(socket)
      assert {:ok, :ping, 1, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>} == SimpleH2Client.recv_frame(socket)
    end
  end

  describe "errors and unexpected frames" do
    test "it should silently ignore client closes", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      SimpleH2Client.send_goaway(socket, 0, 0)
      Transport.close(socket)
      Process.sleep(100)
    end

    @tag :capture_log
    test "it should ignore unknown frame types", context do
      socket = SimpleH2Client.setup_connection(context)
      SimpleH2Client.send_frame(socket, 254, 0, 0, <<>>)
      assert SimpleH2Client.connection_alive?(socket)

      # We can't match on the entire message since it's ordered differently on different OTPs
      assert_receive {:log, %{level: :warning, msg: {:string, msg}}}, 500
      assert msg =~ "Unknown frame"
    end

    @tag :capture_log
    test "it should shut down the connection gracefully and log when encountering a connection error",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send a bogus SETTINGS frame
      SimpleH2Client.send_frame(socket, 4, 0, 1, <<>>)
      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) Invalid SETTINGS frame (RFC9113§6.5)"
    end

    @tag :capture_log
    test "it should shut down the connection gracefully and log when encountering a connection error related to a stream",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send a WINDOW_UPDATE on an idle stream
      SimpleH2Client.send_window_update(socket, 1, 1234)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) Received WINDOW_UPDATE in idle state"
    end

    @tag :capture_log
    test "it should shut down the stream gracefully and log when encountering a stream error",
         context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      # Send trailers with pseudo headers
      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Received trailers with pseudo headers"
    end

    @tag :capture_log
    test "stream errors are short logged by default", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send trailers with pseudo headers
      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Received trailers with pseudo headers"
    end

    @tag :capture_log
    test "StreamError exception includes correct stream_id for different stream IDs", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      port = context[:port]

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", port)

      {:ok, 1, false, _, _} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      # Send trailers with pseudo headers
      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)
      SimpleH2Client.send_headers(socket, 3, true, [{":path", "/foo"}], ctx)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 3, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 3}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Received trailers with pseudo headers"
    end

    @tag :capture_log
    test "stream errors are verbosely logged if so configured", context do
      context =
        context
        |> https_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send trailers with pseudo headers
      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg =~ "** (Bandit.HTTP2.Errors.StreamError) Received trailers with pseudo headers"
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    test "stream errors are not logged if so configured", context do
      context =
        context
        |> https_server(http_options: [log_protocol_errors: false])
        |> Enum.into(context)

      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send trailers with pseudo headers
      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      refute_receive {:log, %{level: :error}}
    end

    test "it should shut down the connection after read timeout has been reached with no initial data sent",
         context do
      context = https_server(context, thousand_island_options: [read_timeout: 100])
      socket = SimpleH2Client.tls_client(context)
      Process.sleep(110)
      assert Transport.recv(socket, 0) == {:error, :closed}
    end

    test "it should shut down the connection after read timeout has been reached with no data sent",
         context do
      context = https_server(context, thousand_island_options: [read_timeout: 100])
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      Process.sleep(110)
      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 0}
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Connection count exceeded"
    end
  end

  describe "settings exchange" do
    test "the server should send a SETTINGS frame at start of the connection", context do
      socket = SimpleH2Client.tls_client(context)
      Transport.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert SimpleH2Client.recv_frame(socket) == {:ok, :settings, 0, 0, <<>>}
    end

    test "the server respects SETTINGS_MAX_FRAME_SIZE as sent by the client", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      SimpleH2Client.exchange_client_settings(socket, <<5::16, 20_000::32>>)
      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_50k", context.port)
      SimpleH2Client.recv_headers(socket)

      expected = String.duplicate("a", 20_000)
      assert {:ok, :data, 0, 1, ^expected} = SimpleH2Client.recv_frame(socket)
      assert {:ok, :data, 0, 1, ^expected} = SimpleH2Client.recv_frame(socket)
      expected = String.duplicate("a", 10_000)
      assert {:ok, :data, 1, 1, ^expected} = SimpleH2Client.recv_frame(socket)
    end

    def send_50k(conn) do
      conn |> send_resp(200, String.duplicate("a", 50_000))
    end

    test "the server preserves existing settings which are NOT sent by the client", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)

      # Send a 20k max frame size setting change
      SimpleH2Client.exchange_client_settings(socket, <<5::16, 20_000::32>>)

      # Now send a 20 max concurrent streams setting change (this doesn't change any
      # of our behaviour since we don't respect this setting, but it demonstrates that
      # we do not overwrite existing settings)
      SimpleH2Client.exchange_client_settings(socket, <<3::16, 20::32>>)

      # We expect to see the 20k max frame setting stick around
      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_50k", context.port)
      SimpleH2Client.recv_headers(socket)

      expected = String.duplicate("a", 20_000)
      assert {:ok, :data, 0, 1, ^expected} = SimpleH2Client.recv_frame(socket)
      assert {:ok, :data, 0, 1, ^expected} = SimpleH2Client.recv_frame(socket)
      expected = String.duplicate("a", 10_000)
      assert {:ok, :data, 1, 1, ^expected} = SimpleH2Client.recv_frame(socket)
    end
  end

  describe "DATA frames" do
    test "sends end of stream when there is a single data frame", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "2"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

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
                {"content-length", "34"},
                {"content-encoding", "deflate"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
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
                {"content-length", "46"},
                {"content-encoding", "gzip"},
                {"vary", "accept-encoding"},
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
                {"content-length", "46"},
                {"content-encoding", "x-gzip"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      expected = :zlib.gzip(String.duplicate("a", 10_000))

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    # TODO Remove conditional once Erlang v28 is required
    if Code.ensure_loaded?(:zstd) do
      test "writes out a response with zstd encoding if so negotiated", context do
        socket = SimpleH2Client.setup_connection(context)

        headers = [
          {":method", "GET"},
          {":path", "/send_big_body"},
          {":scheme", "https"},
          {":authority", "localhost:#{context.port}"},
          {"accept-encoding", "zstd"}
        ]

        SimpleH2Client.send_headers(socket, 1, true, headers)

        assert {:ok, 1, false,
                [
                  {":status", "200"},
                  {"date", _date},
                  {"content-length", "19"},
                  {"content-encoding", "zstd"},
                  {"vary", "accept-encoding"},
                  {"cache-control", "max-age=0, private, must-revalidate"}
                ], _ctx} = SimpleH2Client.recv_headers(socket)

        expected =
          "a"
          |> String.duplicate(10_000)
          |> :zstd.compress()
          |> :erlang.iolist_to_binary()

        assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
      end
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
                {"content-length", "34"},
                {"content-encoding", "deflate"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "does not indicate content encoding or vary for 204 responses", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_204"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, true,
              [
                {":status", "204"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)
    end

    # RFC9110§15.4.5
    test "does not indicate content encoding but indicates vary for 304 responses", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_304"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, true,
              [
                {":status", "304"},
                {"date", _date},
                {"content-length", "5"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)
    end

    test "does not indicate content encoding but indicates vary for zero byte responses",
         context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_empty"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "0"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    def send_empty(conn) do
      conn
      |> send_resp(200, "")
    end

    test "writes out a response with deflate encoding for an iolist body", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_iolist_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "34"},
                {"content-encoding", "deflate"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, body) |> IO.iodata_to_binary()

      assert inflated_body == String.duplicate("a", 10_000)
    end

    test "does no encoding if content-encoding header already present in response", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_content_encoding"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"},
                {"content-encoding", "deflate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      # Assert that we did not try to compress the body
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    test "does no encoding if a strong etag is present in response", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_strong_etag"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"},
                {"etag", "\"1234\""}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      # Assert that we did not try to compress the body
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    test "does content encoding if a weak etag is present in the response", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_weak_etag"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "gzip"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "46"},
                {"content-encoding", "gzip"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"},
                {"etag", "W/\"1234\""}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      expected = :zlib.gzip(String.duplicate("a", 10_000))

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, expected}
    end

    test "does no encoding if cache-control: no-transform is present in the response", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_no_transform"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
                {"cache-control", "no-transform"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      # Assert that we did not try to compress the body
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
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
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
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
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    test "falls back to no encoding if compression is disabled", context do
      context = https_server(context, http_options: [compress: false])

      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/send_big_body"},
        {":scheme", "https"},
        {":authority", "localhost:#{context[:port]}"},
        {"accept-encoding", "deflate"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    def send_big_body(conn) do
      conn
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_iolist_body(conn) do
      conn
      |> send_resp(200, List.duplicate("a", 10_000))
    end

    def send_content_encoding(conn) do
      conn
      |> put_resp_header("content-encoding", "deflate")
      |> put_resp_header("content-length", "10000")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_strong_etag(conn) do
      conn
      |> put_resp_header("etag", "\"1234\"")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_weak_etag(conn) do
      conn
      |> put_resp_header("etag", "W/\"1234\"")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    def send_no_transform(conn) do
      conn
      |> put_resp_header("cache-control", "no-transform")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "sends expected content-length but no body for HEAD requests", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :head, "/send_big_body", context[:port])

      assert {:ok, 1, true,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)
    end

    test "replaces any incorrect provided content-length headers", context do
      context = https_server(context, http_options: [compress: false])

      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(
        socket,
        1,
        :get,
        "/send_incorrect_content_length",
        context[:port]
      )

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "10000"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, String.duplicate("a", 10_000)}
    end

    def send_incorrect_content_length(conn) do
      conn
      |> put_resp_header("content-length", "10001")
      |> send_resp(200, String.duplicate("a", 10_000))
    end

    test "sends no content-length header or body for 204 responses", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_204", context[:port])

      assert {:ok, 1, true,
              [
                {":status", "204"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)
    end

    def send_204(conn) do
      send_resp(conn, 204, "this is an invalid body")
    end

    test "sends content-length header but no body for 304 responses", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_304", context[:port])

      assert {:ok, 1, true,
              [
                {":status", "304"},
                {"date", _date},
                {"content-length", "5"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)
    end

    def send_304(conn) do
      send_resp(conn, 304, "abcde")
    end

    test "sends headers but no body for a HEAD request to a file", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :head, "/send_file", context.port)

      assert {:ok, 1, true,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "6"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def send_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "sends no content-length header or body for a 204 request to a file", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_file_204", context.port)

      assert {:ok, 1, true,
              [
                {":status", "204"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def send_file_204(conn) do
      conn
      |> send_file(204, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "writes out headers but no body for a 304 request to a file", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/send_file_304", context.port)

      assert {:ok, 1, true,
              [
                {":status", "304"},
                {"date", _date},
                {"content-length", "6"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def send_file_304(conn) do
      conn
      |> send_file(304, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "sends multiple DATA frames with last one end of stream when chunking", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/chunk_response", context.port)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "OK"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "DOKEE"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    test "deflate encodes multiple DATA frames when chunking", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/chunk_response"},
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
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      {:ok, 1, false, chunk_1} = SimpleH2Client.recv_body(socket)
      {:ok, 1, false, chunk_2} = SimpleH2Client.recv_body(socket)
      assert {:ok, 1, true, ""} == SimpleH2Client.recv_body(socket)

      inflate_context = :zlib.open()
      :ok = :zlib.inflateInit(inflate_context)
      inflated_body = :zlib.inflate(inflate_context, [chunk_1, chunk_2]) |> IO.iodata_to_binary()

      assert inflated_body == "OKDOKEE"
    end

    test "does not gzip encode DATA frames when chunking", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/chunk_response"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"accept-encoding", "gzip"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert {:ok, 1, false, "OK"} == SimpleH2Client.recv_body(socket)
      assert {:ok, 1, false, "DOKEE"} == SimpleH2Client.recv_body(socket)
    end

    test "does not write out a body for a chunked response to a HEAD request", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :head, "/chunk_response", context.port)

      assert {:ok, 1, true,
              [
                {":status", "200"},
                {"date", _date},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def chunk_response(conn) do
      conn
      |> send_chunked(200)
      |> chunk("OK")
      |> elem(1)
      |> chunk("DOKEE")
      |> elem(1)
    end

    test "does not write out a body for a chunked 204 response", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/chunk_204", context[:port])

      assert {:ok, 1, true,
              [
                {":status", "204"},
                {"date", _date},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def chunk_204(conn) do
      conn
      |> send_chunked(204)
      |> chunk("This is invalid")
      |> elem(1)
    end

    test "does not write out a body for a chunked 304 response", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/chunk_304", context[:port])

      assert {:ok, 1, true,
              [
                {":status", "304"},
                {"date", _date},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    def chunk_304(conn) do
      conn
      |> send_chunked(304)
      |> chunk("This is invalid")
      |> elem(1)
    end

    test "sends multiple DATA frames when sending iolist chunks", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/iolist_chunk_response", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "OK"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, false, "DOKEE"}
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    def iolist_chunk_response(conn) do
      conn
      |> send_chunked(200)
      |> chunk(["OK"])
      |> elem(1)
      |> chunk(["DOKEE"])
      |> elem(1)
    end

    test "reads a zero byte body if none is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/echo", context.port)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""}
    end

    def echo(conn) do
      {:ok, body, conn} = read_body(conn)
      conn |> send_resp(200, body)
    end

    @tag :capture_log
    test "rejects DATA frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 1, true, "OK")
      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Received DATA in idle state"
    end

    test "reads a one frame body if one frame is sent", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)

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
    @tag :capture_log
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
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) invalid content-length header (RFC9112§6.3.5)"
    end

    @tag :capture_log
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
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) invalid content-length header (RFC9112§6.3.5)"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) invalid content-length header (RFC9112§6.3.5)"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Received END_STREAM with byte still pending"
    end

    @tag :capture_log
    test "rejects DATA frames received on a zero stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 0, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) DATA frame with zero stream_id (RFC9113§6.1)"
    end

    @tag :capture_log
    test "rejects DATA frames received on an invalid stream id", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_body(socket, 2, true, "OK")

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Received invalid stream identifier"
    end
  end

  describe "HEADERS frames" do
    test "sends non-end of stream headers when there is a body", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)
      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert(SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"})
    end

    test "sends non-end of stream headers when there is a zero length body", context do
      socket = SimpleH2Client.setup_connection(context)
      SimpleH2Client.send_simple_headers(socket, 1, :get, "/no_body_response", context.port)
      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert(SimpleH2Client.recv_body(socket) == {:ok, 1, true, ""})
    end

    def no_body_response(conn) do
      conn |> send_resp(200, <<>>)
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

      {:ok, :headers, 0, 1, fragment_1} = SimpleH2Client.recv_frame(socket)
      {:ok, :continuation, 0, 1, fragment_2} = SimpleH2Client.recv_frame(socket)
      {:ok, :continuation, 0, 1, fragment_3} = SimpleH2Client.recv_frame(socket)
      {:ok, :continuation, 4, 1, fragment_4} = SimpleH2Client.recv_frame(socket)

      {:ok, headers, _ctx} =
        [fragment_1, fragment_2, fragment_3, fragment_4]
        |> IO.iodata_to_binary()
        |> HPAX.decode(HPAX.new(4096))

      assert [
               {":status", "200"},
               {"date", _date},
               {"content-length", "2"},
               {"vary", "accept-encoding"},
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
      SimpleH2Client.send_frame(socket, 1, 5, 1, headers)

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with priority
      SimpleH2Client.send_frame(socket, 1, 0x25, 1, [<<0, 0, 0, 3, 5>>, headers])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding
      SimpleH2Client.send_frame(socket, 1, 0x0D, 1, [<<4>>, headers, <<1, 2, 3, 4>>])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "accepts well-formed headers with padding and priority", context do
      socket = SimpleH2Client.setup_connection(context)
      headers = headers_for_header_read_test(context)

      # Send headers with padding and priority
      SimpleH2Client.send_frame(socket, 1, 0x2D, 1, [
        <<4, 0, 0, 0, 0, 1>>,
        headers,
        <<1, 2, 3, 4>>
      ])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def headers_for_header_read_test(context) do
      headers = [
        {":method", "GET"},
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

      SimpleH2Client.send_frame(socket, 1, 1, 1, header1)
      SimpleH2Client.send_frame(socket, 9, 0, 1, header2)
      SimpleH2Client.send_frame(socket, 9, 4, 1, header3)

      assert {:ok, 1, false,
              [
                {":status", "200"},
                {"date", _date},
                {"content-length", "2"},
                {"vary", "accept-encoding"},
                {"cache-control", "max-age=0, private, must-revalidate"}
              ], _ctx} = SimpleH2Client.recv_headers(socket)

      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
      assert SimpleH2Client.connection_alive?(socket)
    end

    test "receives header fields in order", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/header_order_test"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"},
        {"x-request-fruit", "banana"},
        {"x-request-fruit", "mango"}
      ]

      ctx = HPAX.new(4096)
      {headers, _} = headers |> Enum.map(fn {k, v} -> {:store, k, v} end) |> HPAX.encode(ctx)
      headers = IO.iodata_to_binary(headers)

      # Send headers with padding
      SimpleH2Client.send_frame(socket, 1, 0x0D, 1, [<<4>>, headers, <<1, 2, 3, 4>>])

      assert {:ok, 1, false, _headers, _ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    def header_order_test(conn) do
      assert conn.req_headers == [{"x-request-fruit", "banana"}, {"x-request-fruit", "mango"}]
      assert get_req_header(conn, "x-request-fruit") == ["banana", "mango"]

      conn |> send_resp(200, "OK")
    end

    @tag :capture_log
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

    @tag :capture_log
    test "rejects HEADER frames sent as trailers that contain pseudo headers", context do
      socket = SimpleH2Client.setup_connection(context)

      {:ok, ctx} = SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, false, "OK")

      {:ok, 0, _} = SimpleH2Client.recv_window_update(socket)
      {:ok, 1, _} = SimpleH2Client.recv_window_update(socket)

      SimpleH2Client.send_headers(socket, 1, true, [{":path", "/foo"}], ctx)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}
      assert SimpleH2Client.connection_alive?(socket)

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received trailers with pseudo headers"
    end

    @tag :capture_log
    test "closes with an error when receiving a zero stream ID", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 0, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) HEADERS frame with zero stream_id (RFC9113§6.2)"
    end

    @tag :capture_log
    test "closes with an error when receiving an even stream ID", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 2, :get, "/echo", context.port)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Received invalid stream identifier"
    end

    @tag :capture_log
    test "closes with an error on a header frame with undecompressable header block", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_frame(socket, 1, 0x2C, 1, <<2, 1::1, 12::31, 34, 1, 2, 3, 4, 5>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 9}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Header decode error"
    end

    @tag :capture_log
    test "returns a stream error if sent headers with uppercase names", context do
      socket = SimpleH2Client.setup_connection(context)

      # Take example from H2Spec
      headers =
        <<130, 135, 68, 137, 98, 114, 209, 65, 226, 240, 123, 40, 147, 65, 139, 8, 157, 92, 11,
          129, 112, 220, 109, 199, 26, 127, 64, 6, 88, 45, 84, 69, 83, 84, 2, 111, 107>>

      SimpleH2Client.send_frame(socket, 1, 5, 1, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received uppercase header"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received invalid pseudo header"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received invalid pseudo header"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Received pseudo headers after regular one"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received connection-specific header"
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

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received invalid TE header"
    end

    @tag :capture_log
    test "returns a stream error if :method pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Expected 1 :method headers"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Expected 1 :method headers"
    end

    @tag :capture_log
    test "returns a stream error if :scheme pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":path", "/"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Expected 1 :scheme headers"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Expected 1 :scheme headers"
    end

    @tag :capture_log
    test "returns a stream error if :path pseudo header is missing", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "HEAD"},
        {":scheme", "https"},
        {":authority", "localhost:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Received empty :path"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Expected 1 :path headers"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Path does not start with /"
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
                {"content-length", "2"},
                {"vary", "accept-encoding"},
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
         {"content-length", "2"},
         {"vary", "accept-encoding"},
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
         {"content-length", "2"},
         {"vary", "accept-encoding"},
         {"cache-control", "max-age=0, private, must-revalidate"}
       ], _ctx} = SimpleH2Client.recv_headers(socket, ctx)

      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}
    end

    @tag :capture_log
    test "returns a stream error if sent header block is too large", context do
      context = https_server(context, http_2_options: [max_header_block_size: 40])
      socket = SimpleH2Client.setup_connection(context)

      headers =
        [
          {":method", "HEAD"},
          {":path", "/"},
          {":scheme", "https"},
          {":authority", "localhost:#{context[:port]}"}
        ] ++ for i <- 1..37, do: {"header#{i}", "foo"}

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Received overlong headers"
    end
  end

  describe "PRIORITY frames" do
    test "receives PRIORITY frames without complaint (and does nothing)", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_priority(socket, 1, 3, 4)

      assert SimpleH2Client.connection_alive?(socket)
    end
  end

  describe "RST_STREAM frames" do
    test "sends RST_FRAME with no error if stream task ends with an unclosed client", context do
      socket = SimpleH2Client.setup_connection(context)

      # Send headers with end_stream bit cleared
      SimpleH2Client.send_simple_headers(socket, 1, :post, "/body_response", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 0}
      assert SimpleH2Client.connection_alive?(socket)
    end

    test "does not send an RST_FRAME if stream task ends with a closed client", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/body_response", context.port)
      SimpleH2Client.recv_headers(socket)
      SimpleH2Client.recv_body(socket)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 0}
    end

    @tag :capture_log
    test "sends RST_FRAME with internal error if we don't set a response with a closed client",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/no_response_get", context.port)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 2}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.StreamError) Terminating stream in remote_closed state"
    end

    def no_response_get(conn) do
      # Ensure we pick up any end_streams that were sent
      {:ok, _, conn} = read_body(conn)
      # We need to manually muck with the Conn to act as if we've already sent a response since we
      # otherwise send an empty response if the user's plug does not
      %{conn | state: :sent}
    end

    @tag :capture_log
    test "sends RST_FRAME with internal error if we don't set a response with an open client",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/no_response_post", context.port)
      assert SimpleH2Client.recv_rst_stream(socket) == {:ok, 1, 2}

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Terminating stream in open state"
    end

    def no_response_post(conn) do
      # We need to manually muck with the Conn to act as if we've already sent a response since we
      # otherwise send an empty response if the user's plug does not
      %{conn | state: :sent}
    end

    @tag :capture_log
    test "rejects RST_STREAM frames received on an idle stream", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_rst_stream(socket, 1, 0)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 1, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.ConnectionError) Received RST_STREAM in idle state"
    end

    @tag :capture_log
    test "raises an error upon receipt of an RST_STREAM frame during reading", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/expect_reset", context.port)
      SimpleH2Client.send_rst_stream(socket, 1, 99)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Received RST_STREAM from client: unknown (99)"
    end

    def expect_reset(conn) do
      read_body(conn)
    end

    @tag :capture_log
    test "raises an error upon receipt of an RST_STREAM frame during writing", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/write_after_delay", context.port)
      SimpleH2Client.send_rst_stream(socket, 1, 99)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Received RST_STREAM from client: unknown (99)"
    end

    def write_after_delay(conn) do
      Process.sleep(10)
      send_resp(conn, 200, "OK")
    end

    test "considers :no_error RST_STREAM frame as a normal closure during chunk writing",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/expect_chunk_error", context.port)
      SimpleH2Client.send_rst_stream(socket, 1, 0)

      refute_receive {:log, %{level: :error}}
    end

    test "considers :cancel RST_STREAM frame as a normal closure during chunk writing",
         context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :get, "/expect_chunk_error", context.port)
      SimpleH2Client.send_rst_stream(socket, 1, 8)

      refute_receive {:log, %{level: :error}}
    end

    def expect_chunk_error(conn) do
      conn = send_chunked(conn, 200)
      Process.sleep(100)
      {:error, :closed} = chunk(conn, "CHUNK")
      conn
    end
  end

  describe "SETTINGS frames" do
    test "the server should acknowledge a client's SETTINGS frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      SimpleH2Client.send_frame(socket, 4, 0, 0, <<>>)
      assert {:ok, :settings, 1, 0, <<>>} == SimpleH2Client.recv_frame(socket)
    end
  end

  describe "PUSH_PROMISE frames" do
    @tag :capture_log
    test "the server should reject any received PUSH_PROMISE frames", context do
      socket = SimpleH2Client.tls_client(context)
      SimpleH2Client.exchange_prefaces(socket)
      SimpleH2Client.send_frame(socket, 5, 0, 1, <<0, 0, 0, 3, 1, 2, 3>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) PUSH_PROMISE frame received (RFC9113§8.4)"
    end
  end

  describe "PING frames" do
    test "the server should acknowledge a client's PING frames", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_frame(socket, 6, 0, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>)
      assert {:ok, :ping, 1, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>} == SimpleH2Client.recv_frame(socket)
    end
  end

  describe "GOAWAY frames" do
    test "the server should send a GOAWAY frame when shutting down", context do
      socket = SimpleH2Client.setup_connection(context)

      assert SimpleH2Client.connection_alive?(socket)

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
      SimpleH2Client.successful_response?(socket, 99, false)
      SimpleH2Client.recv_body(socket)
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

      assert SimpleH2Client.successful_response?(socket, 1, false)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}
    end

    test "manages connection and stream receive windows separately", context do
      socket = SimpleH2Client.setup_connection(context)

      SimpleH2Client.send_simple_headers(socket, 1, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 1, true, "OK")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      {:ok, 0, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert {:ok, 1, false, [{":status", "200"} | _], ctx} = SimpleH2Client.recv_headers(socket)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "OK"}

      SimpleH2Client.send_simple_headers(socket, 3, :post, "/echo", context.port)
      SimpleH2Client.send_body(socket, 3, false, "OK")
      SimpleH2Client.send_body(socket, 3, true, "")

      expected_adjustment = (1 <<< 31) - 1 - 65_535 + 2

      # We should only see a stream update here
      {:ok, 3, ^expected_adjustment} = SimpleH2Client.recv_window_update(socket)

      assert SimpleH2Client.successful_response?(socket, 3, false, ctx)
      assert SimpleH2Client.recv_body(socket) == {:ok, 3, true, "OK"}
    end

    @tag :slow
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
      # 3. Also note that we receive end_of_stream on stream 1 here
      SimpleH2Client.send_window_update(socket, 1, 100)
      SimpleH2Client.send_window_update(socket, 0, 150)
      assert SimpleH2Client.recv_body(socket) == {:ok, 1, true, "d" <> String.duplicate("e", 99)}

      SimpleH2Client.send_window_update(socket, 3, 100)
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
    @tag :capture_log
    test "rejects non-CONTINUATION frames received when end_headers is false", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), _header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      SimpleH2Client.send_frame(socket, 1, 1, 1, header1)
      SimpleH2Client.send_frame(socket, 6, 0, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) Expected CONTINUATION frame (RFC9113§6.10)"
    end

    @tag :capture_log
    test "rejects non-CONTINUATION frames received when from other streams", context do
      socket = SimpleH2Client.setup_connection(context)

      <<header1::binary-size(20), header2::binary-size(20), _header3::binary>> =
        headers_for_header_read_test(context)

      SimpleH2Client.send_frame(socket, 1, 1, 1, header1)
      SimpleH2Client.send_frame(socket, 9, 0, 2, header2)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) Expected CONTINUATION frame (RFC9113§6.10)"
    end

    @tag :capture_log
    test "rejects CONTINUATION frames received when not expected", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = headers_for_header_read_test(context)

      SimpleH2Client.send_frame(socket, 9, 4, 1, headers)

      assert SimpleH2Client.recv_goaway_and_close(socket) == {:ok, 0, 1}

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg ==
               "** (Bandit.HTTP2.Errors.ConnectionError) Received unexpected CONTINUATION frame (RFC9113§6.10)"
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

    test "uses :scheme even if it does not match transport", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "http"},
        {"host", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["scheme"] == "http"
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

    @tag :capture_log
    test "sends 400 if no host header set", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert {:ok, 1, true, [{":status", "400"} | _], _} = SimpleH2Client.recv_headers(socket)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Unable to obtain host and port: No host header"
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

    @tag :capture_log
    test "sends 400 if port cannot be parsed from host header", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "https"},
        {"host", "banana:-1234"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)
      assert {:ok, 1, true, [{":status", "400"} | _], _} = SimpleH2Client.recv_headers(socket)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header contains invalid port"
    end

    test "derives port from schema default if no port specified in host header", context do
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
      assert Jason.decode!(body)["port"] == 443
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

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Path contains dot segment"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Path does not start with /"
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

    test "uses :scheme even if it does not match transport", context do
      socket = SimpleH2Client.setup_connection(context)

      headers = [
        {":method", "GET"},
        {":path", "/echo_components"},
        {":scheme", "http"},
        {":authority", "banana:#{context.port}"}
      ]

      SimpleH2Client.send_headers(socket, 1, true, headers)

      assert SimpleH2Client.successful_response?(socket, 1, false)
      {:ok, 1, true, body} = SimpleH2Client.recv_body(socket)
      assert Jason.decode!(body)["scheme"] == "http"
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

    test "derives port from schema default if no port specified in host header", context do
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
      assert Jason.decode!(body)["port"] == 443
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

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Path contains dot segment"
    end

    @tag :capture_log
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

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: %{stream_id: 1}}}, 500
      assert msg == "** (Bandit.HTTP2.Errors.StreamError) Path does not start with /"
    end
  end

  describe "asterisk-form request target (RFC9113§8.3.1 & RFC9112§3.2.4)" do
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

  describe "process labels" do
    setup do
      context = https_server(%{}, thousand_island_options: [read_timeout: 1000])
      context
    end

    setup :req_h2_client

    test "HTTP/2 handler processes get labeled with client info", context do
      if Util.labels_supported?() do
        # Start a slow request in the background
        task =
          Task.async(fn ->
            Req.get!(context.req, url: "/slow_h2_endpoint")
          end)

        # Give the process time to start and be labeled
        Process.sleep(100)

        processes = Process.list()

        labeled_processes =
          for pid <- processes do
            case Util.get_label(pid) do
              {Bandit.HTTP2.Handler, _client_info} = label ->
                {pid, label}

              _ ->
                nil
            end
          end
          |> Enum.reject(&is_nil/1)

        assert length(labeled_processes) >= 1

        {_pid, {_module, ip_and_port}} = hd(labeled_processes)
        assert Regex.match?(~r/\d+\.\d+\.\d+\.\d+:\d+/, ip_and_port)

        # Wait for the slow request to complete
        response = Task.await(task)
        assert response.status == 200
      end
    end

    def slow_h2_endpoint(conn) do
      Process.sleep(100)
      send_resp(conn, 200, "slow H2 response")
    end
  end
end
