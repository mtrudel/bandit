defmodule HTTP1RequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  setup do
    opts = [port: 0, listener_options: [ip: :loopback]]
    {:ok, server_pid} = start_supervised(Bandit.child_spec(plug: __MODULE__, options: opts))
    {:ok, port} = ThousandIsland.local_port(server_pid)
    {:ok, %{base: "http://localhost:#{port}"}}
  end

  def init(opts) do
    opts
  end

  def call(conn, []) do
    function = String.to_atom(List.first(conn.path_info))
    apply(__MODULE__, function, [conn])
  end

  describe "request handling" do
    test "reads headers and requested metadata properly", %{base: base} do
      {:ok, response} = HTTPoison.get(base <> "/expect_headers/a//b/c?abc=def", [{"X-Fruit", "banana"}])

      assert response.status_code == 200
      assert response.body == "OK"
    end

    def expect_headers(conn) do
      assert conn.request_path == "/expect_headers/a//b/c"
      assert conn.path_info == ["expect_headers", "a", "b", "c"]
      assert conn.query_string == "abc=def"
      assert conn.method == "GET"
      assert conn.remote_ip == "127.0.0.1"
      assert Plug.Conn.get_req_header(conn, "x-fruit") == ["banana"]
      send_resp(conn, 200, "OK")
    end

    test "reads a content-length encoded body properly", %{base: base} do
      {:ok, response} = HTTPoison.post(base <> "/expect_body", String.duplicate("a", 8_000_000))
      assert response.status_code == 200
      assert response.body == "OK"
    end

    def expect_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    test "reads a chunked body properly", %{base: base} do
      stream = Stream.repeatedly(fn -> String.duplicate("a", 1_000_000) end) |> Stream.take(8)

      {:ok, response} =
        HTTPoison.post(base <> "/expect_chunked_body", {:stream, stream}, [
          {"transfer-encoding", "chunked"}
        ])

      assert response.status_code == 200
      assert response.body == "OK"
    end

    def expect_chunked_body(conn) do
      assert Plug.Conn.get_req_header(conn, "transfer-encoding") == ["chunked"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end
  end

  describe "response handling" do
    test "writes out a response with a content-length header", %{base: base} do
      {:ok, response} = HTTPoison.get(base <> "/send_200")
      assert response.status_code == 200
      assert response.body == "OK"
      assert List.first(response.headers) == {"content-length", "2"}
    end

    def send_200(conn) do
      send_resp(conn, 200, "OK")
    end

    test "writes out a chunked response", %{base: base} do
      {:ok, response} = HTTPoison.get(base <> "/send_chunked_200")
      assert response.status_code == 200
      assert response.body == "OK"
      assert List.first(response.headers) == {"transfer-encoding", "chunked"}
    end

    def send_chunked_200(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk("OK")

      conn
    end
  end
end
