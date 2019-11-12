defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket, {plug, plug_opts}) do
    # TODO - would this be easier if we read the headers before passing to plug?
    with {:ok, req} <- Bandit.HTTPRequest.request(socket),
         {:ok, conn} <- Bandit.ConnAdapter.conn(req),
         conn <- plug.call(conn, plug_opts),
         conn <- commit_response(conn) do
      # TODO - only wait if we know we're dealing with an HTTP 1.1
      handle_connection(socket, {plug, plug_opts})
    else
      {:error, _reason} -> ThousandIsland.Socket.close(socket)
    end
  end

  defp commit_response(%Plug.Conn{state: :unset}), do: raise(Plug.Conn.NotSentError)
  defp commit_response(%Plug.Conn{state: :set} = conn), do: Plug.Conn.send_resp(conn)
  defp commit_response(%Plug.Conn{} = conn), do: conn
end
