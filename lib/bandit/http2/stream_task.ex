defmodule Bandit.HTTP2.StreamTask do
  @moduledoc false
  # This Task is where an actual Plug is executed, within the context of an HTTP/2 stream. There
  # is a bit of split responsibility between this module and the `Bandit.HTTP2.Adapter` module
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

  # A stream process can be created only once we have an adapter & set of headers. Pass them in
  # at creation time to ensure this invariant
  @spec start_link(
          Bandit.HTTP2.Adapter.t(),
          Bandit.TransportInfo.t(),
          Plug.Conn.headers(),
          Bandit.Pipeline.plug_def(),
          Bandit.Telemetry.t()
        ) :: {:ok, pid()}
  def start_link(req, transport_info, headers, plug, span) do
    Task.start_link(__MODULE__, :run, [req, transport_info, headers, plug, span])
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

  def run(req, transport_info, all_headers, plug, span) do
    with {:ok, request_target} <- build_request_target(all_headers),
         method <- Bandit.Headers.get_header(all_headers, ":method"),
         req <- %{req | method: method} do
      with {:ok, pseudo_headers, headers} <- split_headers(all_headers),
           :ok <- pseudo_headers_all_request(pseudo_headers),
           :ok <- exactly_one_instance_of(pseudo_headers, ":scheme"),
           :ok <- exactly_one_instance_of(pseudo_headers, ":method"),
           :ok <- exactly_one_instance_of(pseudo_headers, ":path"),
           :ok <- headers_all_lowercase(headers),
           :ok <- no_connection_headers(headers),
           :ok <- valid_te_header(headers),
           headers <- combine_cookie_crumbs(headers),
           req <- Bandit.HTTP2.Adapter.add_end_header_metric(req),
           adapter <- {Bandit.HTTP2.Adapter, req},
           {:ok, %Plug.Conn{adapter: {Bandit.HTTP2.Adapter, req}} = conn} <-
             Bandit.Pipeline.run(adapter, transport_info, method, request_target, headers, plug) do
        Bandit.Telemetry.stop_span(span, req.metrics, %{
          conn: conn,
          method: method,
          request_target: request_target,
          status: conn.status
        })

        :ok
      else
        {:error, reason} ->
          raise Bandit.HTTP2.Stream.StreamError,
            message: reason,
            method: method,
            request_target: request_target
      end
    else
      {:error, reason} -> raise Bandit.HTTP2.Stream.StreamError, reason
    end
  end

  defp build_request_target(headers) do
    with scheme <- Bandit.Headers.get_header(headers, ":scheme"),
         {:ok, host, port} <- get_host_and_port(headers),
         {:ok, path} <- get_path(headers) do
      {:ok, {scheme, host, port, path}}
    end
  end

  defp get_host_and_port(headers) do
    case Bandit.Headers.get_header(headers, ":authority") do
      authority when not is_nil(authority) -> Bandit.Headers.parse_hostlike_header(authority)
      nil -> {:ok, nil, nil}
    end
  end

  # RFC9113§8.3.1 - path should be non-empty and absolute
  defp get_path(headers) do
    headers
    |> Bandit.Headers.get_header(":path")
    |> case do
      nil -> {:error, "Received empty :path"}
      "*" -> {:ok, :*}
      "/" <> _ = path -> split_path(path)
      _ -> {:error, "Path does not start with /"}
    end
  end

  # RFC9113§8.3.1 - path should match the path-absolute production from RFC3986
  defp split_path(path) do
    if path |> String.split("/") |> Enum.all?(&(&1 not in [".", ".."])),
      do: {:ok, path},
      else: {:error, "Path contains dot segment"}
  end

  # RFC9113§8.3 - pseudo headers must appear first
  defp split_headers(headers) do
    {pseudo_headers, headers} =
      Enum.split_while(headers, fn {key, _value} -> String.starts_with?(key, ":") end)

    if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
      do: {:error, "Received pseudo headers after regular one"},
      else: {:ok, pseudo_headers, headers}
  end

  # RFC9113§8.3.1 - only request pseudo headers may appear
  defp pseudo_headers_all_request(headers) do
    if Enum.any?(headers, fn {key, _value} -> key not in ~w[:method :scheme :authority :path] end),
      do: {:error, "Received invalid pseudo header"},
      else: :ok
  end

  # RFC9113§8.3.1 - method, scheme, path pseudo headers must appear exactly once
  defp exactly_one_instance_of(headers, header) do
    headers
    |> Enum.count(fn {key, _value} -> key == header end)
    |> case do
      1 -> :ok
      _ -> {:error, "Expected 1 #{header} headers"}
    end
  end

  # RFC9113§8.2 - all headers name fields must be lowercsae
  defp headers_all_lowercase(headers) do
    if Enum.all?(headers, fn {key, _value} -> lowercase?(key) end),
      do: :ok,
      else: {:error, "Received uppercase header"}
  end

  defp lowercase?(<<char, _rest::bits>>) when char >= ?A and char <= ?Z, do: false
  defp lowercase?(<<_char, rest::bits>>), do: lowercase?(rest)
  defp lowercase?(<<>>), do: true

  # RFC9113§8.2.2 - no hop-by-hop headers
  # Note that we do not filter out the TE header here, since it is allowed in
  # specific cases by RFC9113§8.2.2. We check those cases in a separate filter
  defp no_connection_headers(headers) do
    connection_headers =
      ~w[connection keep-alive proxy-authenticate proxy-authorization trailers transfer-encoding upgrade]

    if Enum.any?(headers, fn {key, _value} -> key in connection_headers end),
      do: {:error, "Received connection-specific header"},
      else: :ok
  end

  # RFC9113§8.2.2 - TE header may be present if it contains exactly 'trailers'
  defp valid_te_header(headers) do
    if Bandit.Headers.get_header(headers, "te") in [nil, "trailers"],
      do: :ok,
      else: {:error, "Received invalid TE header"}
  end

  # Per RFC9113§8.2.3
  defp combine_cookie_crumbs(headers) do
    {crumbs, other_headers} = headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)
    combined_cookie = Enum.map_join(crumbs, "; ", fn {"cookie", crumb} -> crumb end)
    [{"cookie", combined_cookie} | other_headers]
  end
end
