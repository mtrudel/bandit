defmodule ConnPipelineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn

  require Logger

  setup do
    opts = [port: 0, transport_options: [ip: :loopback]]
    {:ok, server_pid} = start_supervised(Bandit.child_spec(plug: __MODULE__, options: opts))
    {:ok, port} = ThousandIsland.local_port(server_pid)
    {:ok, %{base: "http://localhost:#{port}", port: port}}
  end

  def init(opts) do
    opts
  end

  def call(conn, []) do
    function = String.to_atom(List.first(conn.path_info))

    try do
      apply(__MODULE__, function, [conn])
    rescue
      exception ->
        Logger.error(Exception.format(:error, exception, __STACKTRACE__))
        reraise(exception, __STACKTRACE__)
    end
  end

  describe "request handling" do
    test "creates a conn with correct headers and requested metadata", %{base: base} do
      {:ok, response} =
        HTTPoison.get(base <> "/expect_headers/a//b/c?abc=def", [
          {"X-Fruit", "banana"},
          {"connection", "close"}
        ])

      assert response.status_code == 200
      assert response.body == "OK"
    end

    def expect_headers(conn) do
      assert conn.request_path == "/expect_headers/a//b/c"
      assert conn.path_info == ["expect_headers", "a", "b", "c"]
      assert conn.query_string == "abc=def"
      assert conn.method == "GET"
      assert conn.remote_ip == {127, 0, 0, 1}
      assert Plug.Conn.get_req_header(conn, "x-fruit") == ["banana"]
      send_resp(conn, 200, "OK")
    end

    test "returns a 500 if the plug raises an exception", %{base: base} do
      capture_log(fn ->
        {:ok, response} = HTTPoison.get(base <> "/raise_error", [])

        # Let the server shut down so we don't log the error
        Process.sleep(100)

        assert response.status_code == 500
      end)
    end

    def raise_error(_conn) do
      raise "boom"
    end

    test "returns a 400 if the request cannot be parsed", %{port: port} do
      capture_log(fn ->
        {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)
        :gen_tcp.send(client, "GET / HTTP/1.0\r\nGARBAGE\r\n\r\n")
        {:ok, response} = :gen_tcp.recv(client, 0)

        # Let the server shut down so we don't log the error
        Process.sleep(100)

        assert response == 'HTTP/1.0 400\r\n\r\n'
      end)
    end
  end
end
