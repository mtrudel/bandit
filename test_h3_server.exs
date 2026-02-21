Application.ensure_all_started(:bandit)
Application.ensure_all_started(:plug)

defmodule DemoBandit do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "Hello from HTTP/3!\n")
  end

  match _ do
    send_resp(conn, 404, "Not found\n")
  end
end

{:ok, _} =
  Bandit.start_link(
    plug: DemoBandit,
    scheme: :https,
    ip: {127, 0, 0, 1},
    port: 4443,
    certfile: Path.expand("test/support/cert.pem"),
    keyfile: Path.expand("test/support/key.pem"),
    http_3_options: [enabled: true, port: 4444]
  )

IO.puts("ready")
Process.sleep(:infinity)
