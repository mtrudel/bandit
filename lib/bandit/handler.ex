defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket, {plug, plug_opts}) do
    with {:ok, req} <- Bandit.HTTPRequest.request(socket),
         {:ok, conn} <- Bandit.ConnAdapter.conn(req) do
      conn =
        conn
        |> plug.call(plug_opts)
        |> commit_response()

      if keepalive?(conn) do
        handle_connection(socket, {plug, plug_opts})
      end
    else
      {:error, _reason} -> ThousandIsland.Socket.close(socket)
    end
  end

  # TODO - these should be elsewhere

  defp commit_response(%Plug.Conn{state: :unset}), do: raise(Plug.Conn.NotSentError)
  defp commit_response(%Plug.Conn{state: :set} = conn), do: Plug.Conn.send_resp(conn)
  defp commit_response(%Plug.Conn{} = conn), do: conn

  defp keepalive?(%Plug.Conn{adapter: {_, req}}) do
    req.version == "HTTP/1.1"
  end
end
