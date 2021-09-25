defmodule Bandit.HTTP2.StreamTask do
  @moduledoc false
  # This Task is where an actual Plug is executed, within the context of an HTTP/2 stream

  use Task

  alias Bandit.HTTP2.{Adapter, Errors, Stream}

  @spec start_link(
          pid(),
          Stream.stream_id(),
          Plug.Conn.headers(),
          Plug.Conn.Adapter.peer_data(),
          Bandit.plug()
        ) :: {:ok, pid()}
  def start_link(connection, stream_id, headers, peer, plug) do
    Task.start_link(__MODULE__, :run, [connection, stream_id, headers, peer, plug])
  end

  @spec recv_data(pid(), iodata()) :: :ok | :noconnect | :nosuspend
  def recv_data(pid, data), do: Process.send(pid, {:data, data}, [])

  @spec recv_end_of_stream(pid()) :: :ok | :noconnect | :nosuspend
  def recv_end_of_stream(pid), do: Process.send(pid, :end_stream, [])

  @spec recv_rst_stream(pid(), Errors.error_code()) :: true
  def recv_rst_stream(pid, error_code), do: Process.exit(pid, {:recv_rst_stream, error_code})

  @spec run(
          pid(),
          Stream.stream_id(),
          Plug.Conn.headers(),
          Plug.Conn.Adapter.peer_data(),
          Bandit.plug()
        ) ::
          any()
  def run(connection, stream_id, headers, peer, {plug, plug_opts}) do
    headers = combine_cookie_crumbs(headers)
    uri = uri(headers)

    {Adapter, %Adapter{connection: connection, peer: peer, stream_id: stream_id, uri: uri}}
    |> Plug.Conn.Adapter.conn(method(headers), uri, peer.address, headers)
    |> plug.call(plug_opts)
    |> case do
      %Plug.Conn{state: :unset} ->
        raise(Plug.Conn.NotSentError)

      %Plug.Conn{state: :set} = conn ->
        Plug.Conn.send_resp(conn)

      %Plug.Conn{state: :chunked, adapter: {adapter_mod, req}} = conn ->
        adapter_mod.chunk(req, "")
        conn

      %Plug.Conn{} = conn ->
        conn

      _ = conn ->
        raise("Expected #{plug}.call/2 to return %Plug.Conn{} but got: #{inspect(conn)}")
    end
  end

  # Per RFC7540§8.1.2.5
  defp combine_cookie_crumbs(headers) do
    {crumbs, other_headers} = headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)

    combined_cookie = crumbs |> Enum.map(fn {"cookie", crumb} -> crumb end) |> Enum.join("; ")

    other_headers ++ [{"cookie", combined_cookie}]
  end

  defp method(headers), do: get_header(headers, ":method")

  defp uri(headers) do
    scheme = get_header(headers, ":scheme")
    authority = get_header(headers, ":authority")
    path = get_header(headers, ":path")

    # Parse a string to build a URI struct. This is quite a hack and isn't tolerant
    # of requests proxied from an HTTP/1.1 client (RFC7540§8.1.2.3 specifies that
    # :authority MUST NOT be set in this case). In general, canonicalizing URIs is
    # a delicate process & rather than building a half-baked implementation here it's
    # better to leave a simple and ugly hack in place so that future improvements are
    # obvious. Future paths here are discussed at https://github.com/elixir-plug/plug/issues/948)
    URI.parse(scheme <> "://" <> authority <> path)
  end

  defp get_header(headers, header, default \\ nil) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> default
    end
  end
end
