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
      {:ok, headers, method, path, req} ->
        %{address: remote_ip} = adapter_mod.get_peer_data(req)
        %{port: local_port, ssl_cert: ssl_cert} = adapter_mod.get_local_data(req)

        {"host", host} = List.keyfind(headers, "host", 0, {"host", nil})
        scheme = if is_binary(ssl_cert), do: :https, else: :http

        {path, query_string} = path_and_query_string(path)

        {:ok,
         %Conn{
           adapter: {adapter_mod, req},
           owner: self(),
           host: host,
           method: method,
           path_info: String.split(path, "/", trim: true),
           request_path: path,
           port: local_port,
           remote_ip: remote_ip,
           req_headers: headers,
           scheme: scheme,
           query_string: query_string
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp path_and_query_string(path) do
    case String.split(path, "?") do
      [path] -> {path, ""}
      [path, query_string] -> {path, query_string}
    end
  end

  defp commit_response(%Conn{state: :unset}), do: raise(Conn.NotSentError)
  defp commit_response(%Conn{state: :set} = conn), do: Conn.send_resp(conn)
  defp commit_response(%Conn{} = conn), do: conn
end
