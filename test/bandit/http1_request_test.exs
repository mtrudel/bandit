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

  test "handles a basic hello world properly", %{base: base} do
    {:ok, response} = HTTPoison.get(base <> "/send_200")
    assert response.status_code == 200
    assert response.body == "OK"
  end

  def send_200(conn) do
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
end
