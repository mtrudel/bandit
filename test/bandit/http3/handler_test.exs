defmodule Bandit.HTTP3.HandlerTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP3.{Frame, QPACK, Handler}

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  # Build a test quic_fns map whose send/2 forwards captured frames to `pid`.
  defp test_quic_fns(pid, control_stream_id \\ 3) do
    %{
      send: fn stream_id, data, fin ->
        send(pid, {:quic_sent, stream_id, data, fin})
        :ok
      end,
      open_unidirectional: fn -> {:ok, control_stream_id} end
    }
  end

  # Start a Handler with injected quic_fns and return {handler_pid, conn_ref}.
  # `extra_opts` is merged into the base opts map (e.g. %{http_3: [max_field_section_size: 1024]}).
  defp start_handler(plug, extra_opts \\ %{}) do
    test_pid = self()
    conn_ref = make_ref()
    quic_fns = test_quic_fns(test_pid)

    # Minimal opts map that satisfies Bandit.Pipeline expectations
    base_opts = %{http: [], http_3: [], quic_fns: quic_fns}
    opts = Map.merge(base_opts, extra_opts)

    {:ok, handler} = Handler.start_link(nil, conn_ref, plug, opts)
    {handler, conn_ref}
  end

  # Send the "connected" QUIC message to initialise the handler state.
  defp send_connected(handler, conn_ref, peer_ip \\ {127, 0, 0, 1}, peer_port \\ 4433) do
    send(handler, {:quic, conn_ref, {:connected, %{peer_addr: {peer_ip, peer_port}}}})
    # Wait briefly for the handler to process the message
    :timer.sleep(10)
  end

  # Simulate the peer opening a new bidirectional request stream.
  defp send_stream_opened(handler, conn_ref, stream_id) do
    send(handler, {:quic, conn_ref, {:stream_opened, stream_id}})
    :timer.sleep(5)
  end

  # Encode request headers using QPACK and wrap in an HTTP/3 HEADERS frame.
  defp request_headers_frame(headers) do
    block = QPACK.encode_headers(headers)
    Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
  end

  # Decode all quic_sent messages accumulated so far for a stream.
  defp collect_sent(stream_id, acc \\ []) do
    receive do
      {:quic_sent, ^stream_id, data, fin} -> collect_sent(stream_id, [{data, fin} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # Decode the response frames from raw QUIC send captures.
  defp decode_frames(captures) do
    captures
    |> Enum.flat_map(fn {data, _fin} ->
      decode_all_frames(data, [])
    end)
  end

  defp decode_all_frames(<<>>, acc), do: Enum.reverse(acc)

  defp decode_all_frames(data, acc) do
    case Frame.deserialize(data) do
      {:ok, frame, rest} -> decode_all_frames(rest, [frame | acc])
      _ -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Simple echo plug used across tests
  # ---------------------------------------------------------------------------

  defmodule EchoPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      conn |> Plug.Conn.send_resp(200, "echo:#{body}")
    end
  end

  defmodule HelloPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      Plug.Conn.send_resp(conn, 200, "Hello, World!")
    end
  end

  defmodule NotFoundPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  # ---------------------------------------------------------------------------
  # Handler lifecycle
  # ---------------------------------------------------------------------------

  describe "lifecycle" do
    test "starts and stops cleanly" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      assert Process.alive?(handler)
      send(handler, {:quic, conn_ref, {:closed, :normal}})
      :timer.sleep(20)
      refute Process.alive?(handler)
    end

    test "on :connected, sends SETTINGS on control stream" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)

      # Control stream is stream_id=3 per our test_quic_fns stub.
      # We should receive the stream type byte (0x00) + SETTINGS frame.
      assert_receive {:quic_sent, 3, data, false}, 200
      assert <<0x00, rest::binary>> = data
      assert {:ok, {:settings, settings}, <<>>} = Frame.deserialize(rest)
      qpack_id = Frame.settings_qpack_max_table_capacity()
      assert Enum.any?(settings, fn {id, _} -> id == qpack_id end)
    end

    test "ignores unknown QUIC messages" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)
      send(handler, {:quic, conn_ref, {:unknown_event, :whatever}})
      :timer.sleep(10)
      assert Process.alive?(handler)
    end
  end

  # ---------------------------------------------------------------------------
  # Simple GET request (no body)
  # ---------------------------------------------------------------------------

  describe "GET request" do
    test "returns 200 OK with body" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      headers = [
        {":method", "GET"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost"}
      ]

      frame = request_headers_frame(headers)
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      # Collect response frames sent on stream 0
      captures = collect_sent(stream_id)
      frames = decode_frames(captures)

      assert Enum.any?(frames, fn
               {:headers, _} -> true
               _ -> false
             end)

      # Decode the HEADERS frame and check :status
      {:headers, block} = Enum.find(frames, fn {t, _} -> t == :headers end)
      {:ok, resp_headers} = QPACK.decode_headers(block)
      assert Enum.member?(resp_headers, {":status", "200"})

      # Decode the DATA frame and check body
      {:data, body} = Enum.find(frames, fn {t, _} -> t == :data end)
      assert body == "Hello, World!"
    end

    test "returns correct status for non-200 response" do
      {handler, conn_ref} = start_handler({NotFoundPlug, []})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      headers = [
        {":method", "GET"},
        {":path", "/missing"},
        {":scheme", "https"},
        {":authority", "localhost"}
      ]

      frame = request_headers_frame(headers)
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      captures = collect_sent(stream_id)
      frames = decode_frames(captures)

      {:headers, block} = Enum.find(frames, fn {t, _} -> t == :headers end)
      {:ok, resp_headers} = QPACK.decode_headers(block)
      assert Enum.member?(resp_headers, {":status", "404"})
    end
  end

  # ---------------------------------------------------------------------------
  # POST request (with body)
  # ---------------------------------------------------------------------------

  describe "POST request" do
    test "echoes request body" do
      {handler, conn_ref} = start_handler({EchoPlug, []})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      headers = [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost"},
        {"content-length", "5"}
      ]

      headers_frame = request_headers_frame(headers)
      body = "hello"
      data_frame = Frame.serialize({:data, body}) |> IO.iodata_to_binary()

      # Send headers and body in one stream_data message (common QUIC delivery)
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, headers_frame <> data_frame, true}})

      captures = collect_sent(stream_id)
      frames = decode_frames(captures)

      {:headers, block} = Enum.find(frames, fn {t, _} -> t == :headers end)
      {:ok, resp_headers} = QPACK.decode_headers(block)
      assert Enum.member?(resp_headers, {":status", "200"})

      {:data, resp_body} = Enum.find(frames, fn {t, _} -> t == :data end)
      assert resp_body == "echo:#{body}"
    end

    test "body split across multiple stream_data deliveries" do
      {handler, conn_ref} = start_handler({EchoPlug, []})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      headers = [
        {":method", "POST"},
        {":path", "/echo"},
        {":scheme", "https"},
        {":authority", "localhost"},
        {"content-length", "5"}
      ]

      headers_frame = request_headers_frame(headers)
      data_frame1 = Frame.serialize({:data, "hel"}) |> IO.iodata_to_binary()
      data_frame2 = Frame.serialize({:data, "lo"}) |> IO.iodata_to_binary()

      send(handler, {:quic, conn_ref, {:stream_data, stream_id, headers_frame <> data_frame1, false}})
      :timer.sleep(5)
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, data_frame2, true}})

      captures = collect_sent(stream_id)
      frames = decode_frames(captures)

      {:data, resp_body} = Enum.find(frames, fn {t, _} -> t == :data end)
      assert resp_body == "echo:hello"
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple concurrent streams
  # ---------------------------------------------------------------------------

  describe "multiple concurrent streams" do
    test "routes responses to correct streams" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)

      # Open two streams simultaneously
      send_stream_opened(handler, conn_ref, 0)
      send_stream_opened(handler, conn_ref, 4)

      headers = [
        {":method", "GET"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost"}
      ]

      frame = request_headers_frame(headers)

      send(handler, {:quic, conn_ref, {:stream_data, 0, frame, true}})
      send(handler, {:quic, conn_ref, {:stream_data, 4, frame, true}})

      # Each stream should receive its own response
      cap0 = collect_sent(0)
      cap4 = collect_sent(4)

      assert cap0 != []
      assert cap4 != []

      frames0 = decode_frames(cap0)
      frames4 = decode_frames(cap4)

      {:headers, block0} = Enum.find(frames0, fn {t, _} -> t == :headers end)
      {:headers, block4} = Enum.find(frames4, fn {t, _} -> t == :headers end)

      {:ok, h0} = QPACK.decode_headers(block0)
      {:ok, h4} = QPACK.decode_headers(block4)

      assert Enum.member?(h0, {":status", "200"})
      assert Enum.member?(h4, {":status", "200"})
    end
  end

  # ---------------------------------------------------------------------------
  # Header validation
  # ---------------------------------------------------------------------------

  describe "header validation" do
    test "rejects request with uppercase header name" do
      # Missing lower-case enforcement
      defmodule CapHeaderPlug do
        def init(opts), do: opts
        def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
      end

      {handler, conn_ref} = start_handler({CapHeaderPlug, []})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      # Build raw headers with uppercase name (bypass QPACK encoder which lower-cases nothing)
      block = QPACK.encode_headers([
        {":method", "GET"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost"},
        {"X-Custom", "value"}  # uppercase!
      ])

      frame = Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      # Should receive a 400 or the stream process should error — collect sent
      captures = collect_sent(stream_id)

      if captures != [] do
        frames = decode_frames(captures)

        case Enum.find(frames, fn {t, _} -> t == :headers end) do
          {:headers, block} ->
            {:ok, resp_headers} = QPACK.decode_headers(block)
            {_, status} = List.keyfind!(resp_headers, ":status", 0)
            assert String.to_integer(status) >= 400

          nil ->
            # No response sent (stream reset) is also acceptable
            :ok
        end
      end
    end

    test "combines cookie crumbs from multiple headers" do
      defmodule CookieCapturePlug do
        def init(opts), do: opts

        def call(conn, opts) do
          test_pid = opts[:test_pid]
          cookie = Plug.Conn.get_req_header(conn, "cookie")
          send(test_pid, {:cookie, cookie})
          Plug.Conn.send_resp(conn, 200, "ok")
        end
      end

      test_pid = self()
      {handler, conn_ref} = start_handler({CookieCapturePlug, [test_pid: test_pid]})
      send_connected(handler, conn_ref)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      # Two separate cookie headers — QPACK can encode them separately
      block = QPACK.encode_headers([
        {":method", "GET"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost"},
        {"cookie", "a=1"},
        {"cookie", "b=2"}
      ])

      frame = Frame.serialize({:headers, block}) |> IO.iodata_to_binary()
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      assert_receive {:cookie, cookie_val}, 500
      # RFC 9113§8.2.3: cookie crumbs should be combined with "; "
      assert cookie_val == ["a=1; b=2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Connection teardown
  # ---------------------------------------------------------------------------

  describe "connection teardown" do
    test "handler stops when QUIC connection closes" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)
      ref = Process.monitor(handler)

      send(handler, {:quic, conn_ref, {:closed, :normal}})

      assert_receive {:DOWN, ^ref, :process, ^handler, :normal}, 500
    end

    test "handler ignores messages for unknown conn_ref" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)

      other_ref = make_ref()
      send(handler, {:quic, other_ref, {:closed, :normal}})
      :timer.sleep(20)
      assert Process.alive?(handler)
    end
  end

  # ---------------------------------------------------------------------------
  # peer_data / sock_data / ssl_data
  # ---------------------------------------------------------------------------

  describe "metadata calls from stream process" do
    test "peer_data returns the remote address" do
      defmodule PeerDataPlug do
        def init(opts), do: opts

        def call(conn, opts) do
          test_pid = opts[:test_pid]
          send(test_pid, {:peer_data, conn.remote_ip})
          Plug.Conn.send_resp(conn, 200, "ok")
        end
      end

      test_pid = self()
      {handler, conn_ref} = start_handler({PeerDataPlug, [test_pid: test_pid]})
      send_connected(handler, conn_ref, {10, 0, 0, 1}, 9000)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      headers = [
        {":method", "GET"},
        {":path", "/"},
        {":scheme", "https"},
        {":authority", "localhost"}
      ]

      frame = request_headers_frame(headers)
      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      assert_receive {:peer_data, remote_ip}, 500
      assert remote_ip == {10, 0, 0, 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Client control stream handling
  # ---------------------------------------------------------------------------

  describe "client control stream" do
    test "silently consumes client SETTINGS without crashing" do
      {handler, conn_ref} = start_handler({HelloPlug, []})
      send_connected(handler, conn_ref)

      # stream_id=2 is client-initiated unidirectional
      client_control_stream = 2
      send_stream_opened(handler, conn_ref, client_control_stream)

      client_settings =
        <<0x00>> <>
          (Frame.serialize({:settings, [{0x01, 0}, {0x06, 65_536}]}) |> IO.iodata_to_binary())

      send(handler, {:quic, conn_ref, {:stream_data, client_control_stream, client_settings, false}})
      :timer.sleep(20)

      # Handler should still be alive and serving requests
      assert Process.alive?(handler)

      stream_id = 0
      send_stream_opened(handler, conn_ref, stream_id)

      frame =
        request_headers_frame([
          {":method", "GET"},
          {":path", "/"},
          {":scheme", "https"},
          {":authority", "localhost"}
        ])

      send(handler, {:quic, conn_ref, {:stream_data, stream_id, frame, true}})

      captures = collect_sent(stream_id)
      assert captures != []
    end
  end
end
