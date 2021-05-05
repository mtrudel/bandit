defmodule Bandit.HTTP1.Handler do
  @moduledoc """
  An HTTP 1.0 & 1.1 Thousand Island Handler
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{plug: plug} = state) do
    {:ok, adapter_mod, req} = Bandit.HTTP1.Adapter.request(socket, data)

    try do
      case Bandit.ConnPipeline.run(adapter_mod, req, plug) do
        {:ok, req} ->
          if adapter_mod.keepalive?(req) do
            {:ok, :continue, state}
          else
            {:ok, :close, state}
          end

        {:error, code, reason} ->
          adapter_mod.send_fallback_resp(req, code)
          {:error, reason, state}
      end
    rescue
      exception ->
        adapter_mod.send_fallback_resp(req, 500)
        reraise(exception, __STACKTRACE__)
    end
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end
