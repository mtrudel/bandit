defmodule Bandit.ConnPipeline do
  alias Plug.Conn

  def run(adapter_mod, req, {plug, plug_opts}) do
    case conn(adapter_mod, req) do
      {:ok, conn} ->
        %Conn{adapter: {_, req}} =
          conn
          |> plug.call(plug_opts)
          |> commit_response()

        {:ok, req}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conn(adapter_mod, req) do
    case adapter_mod.read_headers(req) do
      {:ok, headers, req} ->
        %{address: remote_ip} = adapter_mod.get_peer_data(req)
        %{port: local_port} = adapter_mod.get_local_data(req)

        # TODO read method / path / querystring etc

        {:ok,
         %Conn{
           adapter: {adapter_mod, req},
           owner: self(),
           remote_ip: remote_ip,
           port: local_port,
           req_headers: headers
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_response(%Conn{state: :unset}), do: raise(Conn.NotSentError)
  defp commit_response(%Conn{state: :set} = conn), do: Conn.send_resp(conn)
  defp commit_response(%Conn{} = conn), do: conn
end
