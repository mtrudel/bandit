defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket, plug) do
    # TODO define & use a parser module to create versioned adapter mods / reqs
    with {:ok, adapter_mod, req} <- Bandit.HTTP1Request.request(socket),
         {:ok, req} <- Bandit.ConnPipeline.run(adapter_mod, req, plug) do
      if adapter_mod.keepalive?(req) do
        handle_connection(socket, plug)
      end
    else
      {:error, _reason} -> ThousandIsland.Socket.close(socket)
    end
  end
end
