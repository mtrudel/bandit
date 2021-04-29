defmodule Bandit.ConnPipeline do
  @moduledoc false

  def run(adapter_mod, req, {plug, plug_opts}) do
    with {:ok, conn} <- build_conn(adapter_mod, req),
         conn <- plug.call(conn, plug_opts),
         %Plug.Conn{adapter: {_, req}} <- commit_response(conn, plug) do
      {:ok, req}
    end
  end

  defp build_conn(adapter_mod, req) do
    case adapter_mod.read_headers(req) do
      {:ok, headers, method, path, req} ->
        %{address: remote_ip} = adapter_mod.get_peer_data(req)
        %{port: local_port, ssl_cert: ssl_cert} = adapter_mod.get_local_data(req)

        {"host", host} = List.keyfind(headers, "host", 0, {"host", nil})
        scheme = if is_binary(ssl_cert), do: :https, else: :http

        {path, query_string} = path_and_query_string(path)

        {:ok,
         %Plug.Conn{
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

      {:error, :timeout} ->
        {:error, 408, "timeout"}

      {:error, reason} ->
        {:error, 400, reason}
    end
  end

  defp commit_response(conn, plug) do
    case conn do
      %Plug.Conn{state: :unset} -> raise(Plug.Conn.NotSentError)
      %Plug.Conn{state: :set} -> Plug.Conn.send_resp(conn)
      %Plug.Conn{} -> conn
      _ -> raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(conn)}")
    end
  end

  defp path_and_query_string(path) do
    case String.split(path, "?") do
      [path] -> {path, ""}
      [path, query_string] -> {path, query_string}
    end
  end
end
