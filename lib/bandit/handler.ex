defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Socket{} = socket, plug) do
    # TODO define & use a parser module to create versioned adapter mods / reqs
    # TODO this always succeeds now, but once we start reading it may fail
    {:ok, adapter_mod, req} = Bandit.HTTP1Request.request(socket)

    try do
      case Bandit.ConnPipeline.run(adapter_mod, req, plug) do
        {:ok, req} ->
          if adapter_mod.keepalive?(req) do
            handle_connection(socket, plug)
          else
            adapter_mod.close(req)
          end

        {:error, code, _reason} ->
          adapter_mod.send_fallback_resp(req, code)
      end
    rescue
      exception ->
        adapter_mod.send_fallback_resp(req, 500)
        reraise exception, __STACKTRACE__
    end
  end
end
