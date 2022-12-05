defmodule Bandit.HTTP2.StreamTask do
  @moduledoc false
  # This Task is where an actual Plug is executed, within the context of an HTTP/2 stream. There
  # is a bit of split responsiblity between this module and the `Bandit.HTTP2.Adapter` module
  # which merits explanation:
  #
  # Broadly, this module is responsible for the execution of a Plug and does so within a Task
  # process. Task is used in preference to GenServer here because of the shape of the
  # `Plug.Conn.Adapter` API (implemented by the `Bandit.HTTP2.Adapter` module). Specifically, that
  # API requires blocking semantics for the `Plug.Conn.Adapter.read_req_body/2`) call and expects
  # it to block until some underlying condition has been met (the body has been read, a timeout
  # has occurred, etc). The events which 'unblock' these conditions typically come from within the
  # Connection, and are pushed down to streams as a fundamental design decision (rather than
  # having stream processes query the connection directly). As such, it is much simpler for Task
  # processes to wait in an imperative fashion using `receive` calls directly.
  #
  # To contain these design decisions, the 'connection-facing' API for sending data to a stream
  # process is expressed on this module (via the `recv_*` functions) even though the 'other half'
  # of those calls exists in the `Bandit.HTTP2.Adapter` module. As a result, this module and the
  # Handler module are fairly tightly coupled, but together they express clear APIs towards both
  # Plug applications and the rest of Bandit.

  use Task

  # A stream process can be created only once we have a stream id & set of headers. Pass them in
  # at creation time to ensure this invariant
  @spec start_link(
          pid(),
          Bandit.HTTP2.Stream.stream_id(),
          Plug.Conn.headers(),
          Plug.Conn.Adapter.peer_data(),
          Bandit.plug()
        ) :: {:ok, pid()}
  def start_link(connection, stream_id, headers, peer, plug) do
    Task.start_link(__MODULE__, :run, [connection, stream_id, headers, peer, plug])
  end

  # Let the stream task know that body data has arrived from the client. The other half of this
  # flow can be found in `Bandit.HTTP2.Adapter.read_req_body/2`
  @spec recv_data(pid(), iodata()) :: :ok | :noconnect | :nosuspend
  def recv_data(pid, data), do: send(pid, {:data, data})

  # Let the stream task know that the client has set the end of stream flag. The other half of
  # this flow can be found in `Bandit.HTTP2.Adapter.read_req_body/2`
  @spec recv_end_of_stream(pid()) :: :ok | :noconnect | :nosuspend
  def recv_end_of_stream(pid), do: send(pid, :end_stream)

  # Let the stream task know that the client has reset the stream. This will terminate the
  # stream's handling process
  @spec recv_rst_stream(pid(), Bandit.HTTP2.Errors.error_code()) :: true
  def recv_rst_stream(pid, error_code), do: Process.exit(pid, {:recv_rst_stream, error_code})

  @spec run(
          pid(),
          Bandit.HTTP2.Stream.stream_id(),
          Plug.Conn.headers(),
          Plug.Conn.Adapter.peer_data(),
          Bandit.plug()
        ) ::
          any()
  def run(connection, stream_id, headers, peer, {plug, plug_opts}) do
    headers = combine_cookie_crumbs(headers)
    uri = uri(headers)

    # Build an Adapter struct and call the actual underlying Plug module
    {Bandit.HTTP2.Adapter,
     %Bandit.HTTP2.Adapter{connection: connection, peer: peer, stream_id: stream_id, uri: uri}}
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

    combined_cookie = Enum.map_join(crumbs, "; ", fn {"cookie", crumb} -> crumb end)

    [{"cookie", combined_cookie} | other_headers]
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
