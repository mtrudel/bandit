defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket_conn, {plug, plug_opts}) do
    socket_conn
    |> Bandit.HTTPRequest.request()
    |> Bandit.ConnAdapter.conn()
    |> plug.call(plug_opts)
    |> commit_response()

    handle_connection(socket_conn, plug)
  end

  defp commit_response(%Plug.Conn{state: :unset}), do: raise(Plug.Conn.NotSentError)
  defp commit_response(%Plug.Conn{state: :set} = conn), do: Plug.Conn.send_resp(conn)
  defp commit_response(%Plug.Conn{} = conn), do: conn
end
