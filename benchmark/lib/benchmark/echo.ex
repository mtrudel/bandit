defmodule Benchmark.Echo do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case read_body(conn) do
      {:ok, nil, conn} -> send_resp(conn, 204, <<>>)
      {:ok, body, conn} -> send_resp(conn, 200, body)
    end
  end
end
