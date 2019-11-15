defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket, plug) do
    with {:ok, req} <- Bandit.HTTP1Request.request(socket),
         {:ok, req} <- Bandit.ConnPipeline.run(req, plug) do
      if Bandit.HTTPRequest.keepalive?(req) do
        handle_connection(socket, plug)
      end
    else
      {:error, _reason} -> ThousandIsland.Socket.close(socket)
    end
  end
end
