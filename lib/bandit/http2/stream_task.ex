defmodule Bandit.HTTP2.StreamTask do
  @moduledoc false

  use Task

  alias Bandit.HTTP2.Adapter

  def start_link(connection, stream_id, headers, peer, plug) do
    Task.start_link(__MODULE__, :run, [connection, stream_id, headers, peer, plug])
  end

  def recv_data(pid, data), do: Process.send(pid, {:data, data}, [])
  def recv_end_of_stream(pid), do: Process.send(pid, :end_stream, [])
  def recv_rst_stream(pid, error_code), do: Process.exit(pid, {:recv_rst_stream, error_code})

  def run(connection, stream_id, headers, peer, {plug, plug_opts}) do
    headers = combine_cookie_crumbs(headers)
    uri = uri(headers)

    {Adapter, %Adapter{connection: connection, peer: peer, stream_id: stream_id, uri: uri}}
    |> conn(method(headers), uri, peer.address, headers)
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

  # TODO - remove this in favour of Plug.Conn.Adapter.conn/5 once Plug > 1.11.1 ships
  defp conn(adapter, method, uri, remote_ip, req_headers) do
    %URI{path: path, host: host, port: port, query: qs, scheme: scheme} = uri

    %Plug.Conn{
      adapter: adapter,
      host: host,
      method: method,
      owner: self(),
      path_info: split_path(path),
      port: port,
      remote_ip: remote_ip,
      query_string: qs || "",
      req_headers: req_headers,
      request_path: path,
      scheme: String.to_atom(scheme)
    }
  end

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    for segment <- segments, segment != "", do: segment
  end

  # Per RFC7540§8.1.2.5
  defp combine_cookie_crumbs(headers) do
    {crumbs, other_headers} = headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)

    combined_cookie = crumbs |> Enum.map(fn {"cookie", crumb} -> crumb end) |> Enum.join("; ")

    other_headers ++ [{"cookie", combined_cookie}]
  end

  defp method(headers), do: get_header(headers, ":method")

  # Build up a URI based on RFC7540§8.1.2.3
  # TODO - This is a bogus hack since the interface into URI is so anemic
  # See https://github.com/elixir-plug/plug/issues/948 for future paths here
  defp uri(headers) do
    scheme = get_header(headers, ":scheme")
    authority = get_header(headers, ":authority")
    path = get_header(headers, ":path")
    URI.parse(scheme <> "://" <> authority <> path)
  end

  defp get_header(headers, header, default \\ nil) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> default
    end
  end
end
