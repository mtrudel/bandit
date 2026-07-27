defmodule HTTP1TelemetryTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  setup :http_server
  setup :req_http1_client

  describe "telemetry" do
    test "it should send `start` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :start], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_200"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should send `stop` events for normally completing requests", context do
      Req.get!(context.req, url: "/send_200")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 0,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_200"]),
               plug: {__MODULE__, []}
             }
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "it should add req metrics to `stop` events for requests with no request body",
         context do
      Req.post!(context.req, url: "/do_read_body", body: <<>>)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 0,
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
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
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 80,
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add req metrics to `stop` events for chunked request body", context do
      stream = Stream.repeatedly(fn -> "a" end) |> Stream.take(80)
      Req.post!(context.req, url: "/do_read_body", body: stream)

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 80,
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
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
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               req_body_start_time: integer(roughly: System.monotonic_time()),
               req_body_end_time: integer(roughly: System.monotonic_time()),
               req_body_bytes: 80,
               resp_uncompressed_body_bytes: 2,
               resp_body_bytes: 22,
               resp_compression_method: "gzip",
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["do_read_body"]),
               plug: {__MODULE__, []}
             }
    end

    test "it should add (some) resp metrics to `stop` events for chunked responses", context do
      Req.get!(context.req, url: "/send_chunked_200")

      assert_receive {:telemetry, [:bandit, :request, :stop], measurements, metadata}, 500

      assert measurements
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 2,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_chunked_200"]),
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
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native)),
               req_header_end_time: integer(roughly: System.monotonic_time()),
               resp_body_bytes: 6,
               resp_start_time: integer(roughly: System.monotonic_time()),
               resp_end_time: integer(roughly: System.monotonic_time())
             }

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["send_full_file"]),
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
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native))
             }

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
             ~> %{
               monotonic_time: integer(roughly: System.monotonic_time()),
               duration: integer(max: System.convert_time_unit(1, :second, :native))
             }

      assert(
        metadata
        ~> %{
          plug: {__MODULE__, []},
          connection_telemetry_span_context: reference(),
          telemetry_span_context: reference(),
          error: "Read timeout"
        }
      )
    end

    @tag :capture_log
    test "it should send `exception` events for raising requests", context do
      Req.get!(context.req, url: "/raise_error")

      assert_receive {:telemetry, [:bandit, :request, :exception], measurements, metadata}, 500

      assert measurements
             ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["raise_error"]),
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
             ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["uncaught_throw"]),
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
             ~> %{monotonic_time: integer(roughly: System.monotonic_time())}

      assert metadata
             ~> %{
               connection_telemetry_span_context: reference(),
               telemetry_span_context: reference(),
               conn: struct_like(Plug.Conn, path_info: ["uncaught_exit"]),
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
