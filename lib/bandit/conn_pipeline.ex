defmodule Bandit.ConnPipeline do
  @moduledoc false

  def run(adapter_mod, req, plug) do
    with {:ok, conn} <- build_conn(adapter_mod, req),
         conn <- call_plug(conn, plug),
         %Plug.Conn{adapter: {_, req}} <- commit_response(conn, plug) do
      {:ok, req}
    end
  end

  defp build_conn(adapter_mod, req) do
    case adapter_mod.read_headers(req) do
      {:ok, headers, method, path, req} ->
        %{address: remote_ip} = adapter_mod.get_peer_data(req)
        %{port: local_port} = adapter_mod.get_local_data(req)

        {"host", host} = List.keyfind(headers, "host", 0, {"host", nil})
        scheme = if adapter_mod.secure?(req), do: :https, else: :http

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
        attempt_to_send_fallback({adapter_mod, req}, 408)
        {:error, "timeout reading request"}

      {:error, reason} ->
        attempt_to_send_fallback({adapter_mod, req}, 400)
        {:error, reason}
    end
  end

  defp call_plug(%Plug.Conn{adapter: adapter} = conn, {plug, plug_opts}) do
    plug.call(conn, plug_opts)
  rescue
    exception ->
      attempt_to_send_fallback(adapter, 500)
      reraise(exception, __STACKTRACE__)
  end

  defp commit_response(conn, plug) do
    case conn do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} ->
        Plug.Conn.send_resp(conn)

      %Plug.Conn{state: :chunked, adapter: {adapter_mod, req}} ->
        adapter_mod.chunk(req, "")
        conn

      %Plug.Conn{} ->
        conn

      _ ->
        raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(conn)}")
    end
  end

  defp path_and_query_string(path) do
    case String.split(path, "?") do
      [path] -> {path, ""}
      [path, query_string] -> {path, query_string}
    end
  end

  defp attempt_to_send_fallback({adapter_mod, req}, code) do
    adapter_mod.send_resp(req, code, [], <<>>)
  rescue
    _ -> :ok
  end
end
