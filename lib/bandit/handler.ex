defmodule Bandit.Handler do
  @moduledoc false

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, plug) do
    {:ok, adapter_mod, req} = Bandit.HTTP1Request.request(socket, data)

    try do
      case Bandit.ConnPipeline.run(adapter_mod, req, plug) do
        {:ok, req} ->
          if adapter_mod.keepalive?(req) do
            {:ok, :continue, plug}
          else
            {:ok, :close, plug}
          end

        {:error, code, reason} ->
          adapter_mod.send_fallback_resp(req, code)
          {:error, reason, plug}
      end
    rescue
      exception ->
        adapter_mod.send_fallback_resp(req, 500)
        {:error, exception, plug}
    end
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end
