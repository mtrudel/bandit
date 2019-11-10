defmodule Bandit.Handler do
  alias ThousandIsland.Connection

  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(conn, {_plug, _plug_opts}) do
    Connection.recv(conn)
    Connection.send(conn, "HTTP/1.1 200\r\n\r\nHello")
  end
end
