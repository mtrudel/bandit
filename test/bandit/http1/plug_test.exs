defmodule HTTP1PlugTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  require Logger

  setup :http_server
  setup :req_http1_client

  describe "plug definitions" do
    test "runs module plugs", context do
      response = Req.get!(context.req, url: "/hello_world")
      assert response.status == 200
      assert response.body == "OK module"
    end

    def hello_world(conn) do
      send_resp(conn, 200, "OK module")
    end

    test "runs function plugs", context do
      context =
        context
        |> http_server(plug: fn conn, _ -> send_resp(conn, 200, "OK function") end)
        |> Enum.into(context)

      response = Req.get!(context.req, url: "/", base_url: context.base)
      assert response.status == 200
      assert response.body == "OK function"
    end
  end

  describe "plug error handling" do
    @tag :capture_log
    test "it should return 500, close the connection and log verbosely when unknown exceptions are raised",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/unknown_crasher", ["host: banana"])

      assert {:ok, "500 Internal Server Error", _headers, _} =
               SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: meta}}, 500
      assert msg =~ "(ArithmeticError)"
      assert msg =~ "lib/bandit/pipeline.ex:"

      assert %{
               domain: [:elixir, :bandit],
               crash_reason: {%ArithmeticError{}, [_ | _] = _stacktrace},
               conn: %Plug.Conn{},
               plug: {__MODULE__, []}
             } = meta
    end

    def unknown_crasher(_conn) do
      1 + self()
    end

    @tag :capture_log
    test "it should return the code, close the connection and not log when known exceptions are raised",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/known_crasher", ["host: banana"])

      assert {:ok, "418 I'm a teapot", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)

      refute_receive {:log, _}
    end

    @tag :capture_log
    test "it should verbosely log known exceptions if so configured", context do
      context =
        context
        |> http_server(http_options: [log_exceptions_with_status_codes: 100..599])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/known_crasher", ["host: banana"])

      assert {:ok, "418 I'm a teapot", _headers, _} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "(SafeError) boom"
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    def known_crasher(_conn) do
      raise SafeError, "boom"
    end

    defmodule Router do
      use Plug.Router
      plug(Plug.Logger)
      plug(:match)
      plug(:dispatch)

      get "/hello_world" do
        send_resp(conn, 200, "hello")
      end

      get "/" do
        # Quiet the compiler
        _ = conn
        1 = 0
      end
    end

    @tag :capture_log
    test "it should unwrap Plug.Conn.WrapperErrors and handle the inner error", context do
      context =
        context
        |> http_server(plug: Router)
        |> Enum.into(context)

      LoggerHelpers.receive_all_log_events(Router)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/", ["host: banana"])

      assert {:ok, "500 Internal Server Error", _headers, _} =
               SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/hello_world", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}, meta: meta}}, 500
      refute msg =~ "(Plug.Conn.WrapperError)"
      assert msg =~ "** (MatchError)"

      assert %{
               domain: [:elixir, :bandit],
               crash_reason: {%MatchError{}, [_ | _] = _stacktrace},
               conn: %Plug.Conn{}
             } = meta
    end
  end

  describe "request isolation" do
    test "logger metadata is reset on every request", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/metadata", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "[]"} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/metadata", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "[]"} = SimpleHTTP1Client.recv_reply(client)
    end

    def metadata(conn) do
      existing_metadata = Logger.metadata()
      Logger.metadata(add: :garbage)
      send_resp(conn, 200, inspect(existing_metadata))
    end

    test "process dictionary is reset on every request", context do
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/pdict", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "[]"} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/pdict", ["host: localhost"])
      assert {:ok, "200 OK", _headers, "[]"} = SimpleHTTP1Client.recv_reply(client)
    end

    def pdict(conn) do
      existing_pdict =
        Process.get() |> Keyword.drop(~w[$ancestors $initial_call]a)

      Process.put(:garbage, :garbage)
      Process.put({:garbage, :test}, :garbage)
      send_resp(conn, 200, inspect(existing_pdict))
    end

    test "gc_every_n_keepalive_requests is respected", context do
      context =
        context
        |> http_server(http_1_options: [gc_every_n_keepalive_requests: 3])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/do_gc", ["host: localhost"])
      {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/heap_size", ["host: localhost"])
      {:ok, "200 OK", _headers, initial_heap_size} = SimpleHTTP1Client.recv_reply(client)

      SimpleHTTP1Client.send(client, "GET", "/heap_size", ["host: localhost"])
      {:ok, "200 OK", _headers, penultimate_heap_size} = SimpleHTTP1Client.recv_reply(client)

      # This one should have been gc'd
      SimpleHTTP1Client.send(client, "GET", "/heap_size", ["host: localhost"])
      {:ok, "200 OK", _headers, final_heap_size} = SimpleHTTP1Client.recv_reply(client)

      assert String.to_integer(initial_heap_size) <= String.to_integer(penultimate_heap_size)
      assert String.to_integer(final_heap_size) <= String.to_integer(penultimate_heap_size)
    end

    def do_gc(conn) do
      :erlang.garbage_collect(self())
      send_resp(conn, 200, "OK")
    end

    def heap_size(conn) do
      # Exercise the heap a bit
      _trash = String.duplicate("a", 10_000) |> :binary.bin_to_list()
      {:heap_size, heap_size} = :erlang.process_info(self(), :heap_size)
      send_resp(conn, 200, inspect(heap_size))
    end
  end

  describe "reading requests" do
    test "reading request body multiple times works as expected", context do
      response = Req.post!(context.req, url: "/multiple_body_read", body: "OK")

      assert response.status == 200
    end

    def multiple_body_read(conn) do
      {:ok, body, conn} = read_body(conn)
      assert body == "OK"
      {:ok, "", conn} = read_body(conn)
      conn |> send_resp(200, body)
    end
  end

  describe "upgrade handling" do
    @tag :capture_log
    test "raises an ArgumentError on unsupported upgrades", context do
      response = Req.get!(context.req, url: "/upgrade_unsupported")

      assert response.status == 500

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (ArgumentError) upgrade to unsupported not supported by Bandit.Adapter"
    end

    def upgrade_unsupported(conn) do
      conn
      |> upgrade_adapter(:unsupported, nil)
      |> send_resp(200, "Not supported")
    end
  end

  describe "response headers" do
    test "writes out a response with a valid date header", context do
      response = Req.get!(context.req, url: "/send_200")

      assert response.status == 200

      [date] = response.headers["date"]
      assert DateHelpers.valid_date_header?(date)
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "returns user-defined date header instead of internal version", context do
      response = Req.get!(context.req, url: "/date_header")

      assert response.status == 200

      [date] = response.headers["date"]
      assert date == "Tue, 27 Sep 2022 07:17:32 GMT"
    end

    def date_header(conn) do
      conn
      |> put_resp_header("date", "Tue, 27 Sep 2022 07:17:32 GMT")
      |> send_resp(200, "OK")
    end
  end

  describe "supporting plug functions" do
    test "reading HTTP version", context do
      response = Req.get!(context.req, url: "/report_version")

      assert response.status == 200
      assert response.body == "HTTP/1.1"
    end

    def report_version(conn) do
      send_resp(conn, 200, conn |> get_http_protocol() |> to_string())
    end

    test "reading peer data", context do
      # Use a manually built request so we can read the local port
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/peer_data", ["host: localhost"])
      {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      {:ok, {ip, port}} = Transport.sockname(client)

      assert body == inspect(%{address: ip, port: port, ssl_cert: nil})
    end

    def peer_data(conn) do
      send_resp(conn, 200, conn |> get_peer_data() |> inspect())
    end
  end

  describe "plug return values" do
    @tag :capture_log
    test "does not send an error response if the plug has already sent one before raising",
         context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/send_and_raise_error", ["host: banana"])
      assert {:ok, "200 OK", _headers, _} = SimpleHTTP1Client.recv_reply(client)
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "(RuntimeError) boom"
    end

    def send_and_raise_error(conn) do
      send_resp(conn, 200, "OK")
      raise "boom"
    end

    @tag :capture_log
    test "returns a 500 if the plug does not return anything", context do
      response = Req.get!(context.req, url: "/noop")
      assert response.status == 500

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg =~
               "(Plug.Conn.NotSentError) a response was neither set nor sent from the connection"
    end

    def noop(conn) do
      conn
    end

    @tag :capture_log
    test "returns a 500 if the plug does not return a conn", context do
      response = Req.get!(context.req, url: "/return_garbage")

      assert response.status == 500

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

      assert msg =~
               "(RuntimeError) Expected Elixir.HTTP1PlugTest.call/2 to return %Plug.Conn{} but got: :nope"
    end

    def return_garbage(_conn) do
      :nope
    end
  end

  describe "process concerns" do
    test "survives EXIT messages from normally terminating spawned processes", context do
      response = Req.get!(context.req, url: "/spawn_child")
      assert response.status == 204

      refute_receive {:log, _}
    end

    def spawn_child(conn) do
      spawn_link(fn -> exit(:normal) end)
      Process.sleep(10)
      send_resp(conn, 204, "")
    end

    @tag :capture_log
    test "survives EXIT messages from abnormally terminating spawned processes", context do
      response = Req.get!(context.req, url: "/spawn_abnormal_child")
      assert response.status == 204

      refute_receive {:log, _}
    end

    def spawn_abnormal_child(conn) do
      spawn_link(fn -> exit(:abnormal) end)
      Process.sleep(10)
      send_resp(conn, 204, "")
    end
  end

  describe "telemetry" do
    test "it should send `start` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :start], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    test "it should send `stop` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               resp_body_bytes: 0,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for requests with no request body",
         context do
      Req.post!(context.req, url: "/do_read_body", body: <<>>)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               req_body_start_time: integer(),
               req_body_end_time: integer(),
               req_body_bytes: 0,
               resp_body_bytes: 2,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    def do_read_body(conn) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 200, "OK")
    end

    test "it should add req metrics to `stop` events for requests with request body", context do
      Req.post!(context.req, url: "/do_read_body", body: String.duplicate("a", 80))

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               req_body_start_time: integer(),
               req_body_end_time: integer(),
               req_body_bytes: 80,
               resp_body_bytes: 2,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for chunked request body", context do
      stream = Stream.repeatedly(fn -> "a" end) |> Stream.take(80)
      Req.post!(context.req, url: "/do_read_body", body: stream)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               req_body_start_time: integer(),
               req_body_end_time: integer(),
               req_body_bytes: 80,
               resp_body_bytes: 2,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for requests with content encoding",
         context do
      Req.post!(context.req,
        url: "/do_read_body",
        body: String.duplicate("a", 80),
        headers: [{"accept-encoding", "gzip"}]
      )

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               req_body_start_time: integer(),
               req_body_end_time: integer(),
               req_body_bytes: 80,
               resp_uncompressed_body_bytes: 2,
               resp_body_bytes: 22,
               resp_compression_method: "gzip",
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    test "it should add (some) resp metrics to `stop` events for chunked responses", context do
      Req.get!(context.req, url: "/send_chunked_200")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               resp_body_bytes: 2,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    def send_chunked_200(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk("OK")

      conn
    end

    test "it should add resp metrics to `stop` events for sendfile responses", context do
      Req.get!(context.req, url: "/send_full_file")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(),
               duration: integer(),
               req_header_end_time: integer(),
               resp_body_bytes: 6,
               resp_start_time: integer(),
               resp_end_time: integer()
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []}
             }
    end

    def send_full_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    @tag :capture_log
    test "it should send `stop` events for malformed requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer(), duration: integer()}

      assert metadata
             ~> %{
               plug: {__MODULE__, []},
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               error: string()
             }
    end

    @tag :capture_log
    test "it should send `stop` events for timed out requests", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nfoo: bar\r\n")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer(), duration: integer()}

      assert(
        metadata
        ~> %{
          plug: {__MODULE__, []},
          connection_telemetry_span_context: reference(),
          telemetry_span_context: reference(),
          error: "Header read timeout"
        }
      )
    end

    @tag :capture_log
    test "it should send `exception` events for raising requests", context do
      Req.get!(context.req, url: "/raise_error")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer()}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []},
               kind: :exit,
               exception: %RuntimeError{message: "boom"},
               stacktrace: list()
             }
    end

    def raise_error(_conn) do
      raise "boom"
    end

    @tag :capture_log
    test "it should send `exception` events for throwing requests", context do
      Req.get!(context.req, url: "/uncaught_throw")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer()}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []},
               kind: :throw,
               exception: "thrown",
               stacktrace: list()
             }
    end

    def uncaught_throw(_conn) do
      throw("thrown")
    end

    @tag :capture_log
    test "it should send `exception` events for exiting requests", context do
      Req.get!(context.req, url: "/uncaught_exit")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer()}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, []),
               plug: {__MODULE__, []},
               kind: :exit,
               exception: "exited",
               stacktrace: list()
             }
    end

    def uncaught_exit(_conn) do
      exit("exited")
    end
  end
end
