defmodule Bandit.HTTP1.ConnPipeline do
  @moduledoc false

  alias Bandit.HTTP1.Adapter

  def run(data, socket, plug) do
    with req <- %Adapter{socket: socket, buffer: data},
         {:ok, conn} <- build_conn(req),
         conn <- call_plug(conn, plug),
         %Plug.Conn{adapter: {_, req}} <- commit_response(conn, plug) do
      {:ok, Adapter.keepalive?(req)}
    end
  end

  defp build_conn(req) do
    case Adapter.read_headers(req) do
      {:ok, headers, method, path, req} ->
        %{address: remote_ip} = Adapter.get_peer_data(req)

        # Parse a string to build a URI struct. This is quite a hack In general, canonicalizing
        # URIs is a delicate process & rather than building a half-baked implementation here it's
        # better to leave a simple and ugly hack in place so that future improvements are obvious.
        # Future paths here are discussed at https://github.com/elixir-plug/plug/issues/948)
        {"host", host} = List.keyfind(headers, "host", 0, {"host", nil})
        scheme = if Adapter.secure?(req), do: :https, else: :http
        uri = URI.parse("#{scheme}://#{host}#{path}")
        {:ok, Plug.Conn.Adapter.conn({Adapter, req}, method, uri, remote_ip, headers)}

      {:error, :timeout} ->
        attempt_to_send_fallback(req, 408)
        {:error, "timeout reading request"}

      {:error, reason} ->
        attempt_to_send_fallback(req, 400)
        {:error, reason}
    end
  end

  defp call_plug(%Plug.Conn{adapter: {Adapter, req}} = conn, {plug, plug_opts}) do
    plug.call(conn, plug_opts)
  rescue
    exception ->
      attempt_to_send_fallback(req, 500)
      reraise(exception, __STACKTRACE__)
  end

  defp commit_response(conn, plug) do
    case conn do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} ->
        Plug.Conn.send_resp(conn)

      %Plug.Conn{state: :chunked, adapter: {Adapter, req}} ->
        Adapter.chunk(req, "")
        conn

      %Plug.Conn{} ->
        conn

      _ ->
        raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(conn)}")
    end
  end

  defp attempt_to_send_fallback(req, code) do
    Adapter.send_resp(req, code, [], <<>>)
  rescue
    _ -> :ok
  end
end
