defmodule Bandit.HTTP2.StreamTransport do
  @moduledoc """
  TODO
  """

  # We purposefully use raw `receive` message patterns in this module in order to facilitate an
  # imperatively structured blocking interface as required by `Plug.Conn.Adapter`. This is very
  # unconventional but also safe, so long as the receive patterns expressed below are extremely
  # tight

  # We also use exceptions by convention here rather than error tuples since many
  # of these functions are called within Plug.Conn.Adapter calls, which makes it
  # difficult to properly unwind many error conditions back to a killed stream process
  # and a RstStream frame to the client. The pattern here is to raise exceptions,
  # and have the StreamProcess' `terminate/2` callback take care of shutting down the stream with
  # the luxury of a nicely unwound stack

  require Integer

  defstruct connection_pid: nil,
            stream_id: nil,
            recv_window_size: 65_535,
            send_window_size: nil,
            bytes_remaining: nil,
            transport_info: nil

  @typedoc "The information necessary to communicate to/from a stream"
  @type t :: %__MODULE__{
          connection_pid: pid(),
          stream_id: non_neg_integer(),
          recv_window_size: non_neg_integer(),
          send_window_size: non_neg_integer(),
          bytes_remaining: non_neg_integer() | nil,
          transport_info: Bandit.TransportInfo.t()
        }

  def new(connection_pid, stream_id, initial_send_window_size, transport_info) do
    %__MODULE__{
      connection_pid: connection_pid,
      stream_id: stream_id,
      send_window_size: initial_send_window_size,
      transport_info: transport_info
    }
  end

  def start_stream(%__MODULE__{} = stream_transport) do
    stream_id_is_valid_client!(stream_transport.stream_id)
    stream_transport
  end

  # RFC9113§5.1.1 - client initiated streams must be odd
  defp stream_id_is_valid_client!(stream_id) do
    if Integer.is_even(stream_id) do
      connection_error!("Received HEADERS with even stream_id")
    end
  end

  def recv_headers(stream_transport) do
    receive do
      {:headers, headers} ->
        do_recv_headers(stream_transport, headers)
        # TODO timeout
    end
  end

  defp do_recv_headers(%__MODULE__{state: :idle} = stream_transport, headers) do
    method = Bandit.Headers.get_header(headers, ":method")
    request_target = build_request_target!(headers)

    try do
      {pseudo_headers, headers} = split_headers!(headers)
      pseudo_headers_all_request!(pseudo_headers)
      exactly_one_instance_of!(pseudo_headers, ":scheme")
      exactly_one_instance_of!(pseudo_headers, ":method")
      exactly_one_instance_of!(pseudo_headers, ":path")
      headers_all_lowercase!(headers)
      no_connection_headers!(headers)
      valid_te_header!(headers)
      content_length = get_content_length!(headers)
      headers = combine_cookie_crumbs(headers)
      stream_transport = %{stream_transport | bytes_remaining: content_length}
      {:ok, method, request_target, headers, stream_transport}
    rescue
      exception ->
        reraise %{exception | method: method, request_target: request_target}, __STACKTRACE__
    end
  end

  defp build_request_target!(headers) do
    with scheme <- Bandit.Headers.get_header(headers, ":scheme"),
         {:ok, host, port} <- get_host_and_port(headers),
         path <- get_path!(headers) do
      {scheme, host, port, path}
    end
  end

  defp get_host_and_port(headers) do
    case Bandit.Headers.get_header(headers, ":authority") do
      authority when not is_nil(authority) -> Bandit.Headers.parse_hostlike_header(authority)
      nil -> {:ok, nil, nil}
    end
  end

  # RFC9113§8.3.1 - path should be non-empty and absolute
  defp get_path!(headers) do
    headers
    |> Bandit.Headers.get_header(":path")
    |> case do
      nil -> stream_error!("Received empty :path")
      "*" -> :*
      "/" <> _ = path -> split_path!(path)
      _ -> stream_error!("Path does not start with /")
    end
  end

  # RFC9113§8.3.1 - path should match the path-absolute production from RFC3986
  defp split_path!(path) do
    if path |> String.split("/") |> Enum.all?(&(&1 not in [".", ".."])),
      do: path,
      else: stream_error!("Path contains dot segment")
  end

  # RFC9113§8.3 - pseudo headers must appear first
  defp split_headers!(headers) do
    {pseudo_headers, headers} =
      Enum.split_while(headers, fn {key, _value} -> String.starts_with?(key, ":") end)

    if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
      do: stream_error!("Received pseudo headers after regular one"),
      else: {pseudo_headers, headers}
  end

  # RFC9113§8.3.1 - only request pseudo headers may appear
  defp pseudo_headers_all_request!(headers) do
    if Enum.any?(headers, fn {key, _value} -> key not in ~w[:method :scheme :authority :path] end),
      do: stream_error!("Received invalid pseudo header")
  end

  # RFC9113§8.3.1 - method, scheme, path pseudo headers must appear exactly once
  defp exactly_one_instance_of!(headers, header) do
    headers
    |> Enum.count(fn {key, _value} -> key == header end)
    |> case do
      1 -> :ok
      _ -> stream_error!("Expected 1 #{header} headers")
    end
  end

  # RFC9113§8.2 - all headers name fields must be lowercsae
  defp headers_all_lowercase!(headers) do
    if !Enum.all?(headers, fn {key, _value} -> lowercase?(key) end),
      do: stream_error!("Received uppercase header")
  end

  defp lowercase?(<<char, _rest::bits>>) when char >= ?A and char <= ?Z, do: false
  defp lowercase?(<<_char, rest::bits>>), do: lowercase?(rest)
  defp lowercase?(<<>>), do: true

  # RFC9113§8.2.2 - no hop-by-hop headers
  # Note that we do not filter out the TE header here, since it is allowed in
  # specific cases by RFC9113§8.2.2. We check those cases in a separate filter
  defp no_connection_headers!(headers) do
    connection_headers =
      ~w[connection keep-alive proxy-authenticate proxy-authorization trailers transfer-encoding upgrade]

    if Enum.any?(headers, fn {key, _value} -> key in connection_headers end),
      do: stream_error!("Received connection-specific header")
  end

  # RFC9113§8.2.2 - TE header may be present if it contains exactly 'trailers'
  defp valid_te_header!(headers) do
    if Bandit.Headers.get_header(headers, "te") not in [nil, "trailers"],
      do: stream_error!("Received invalid TE header")
  end

  defp get_content_length!(headers) do
    case Bandit.Headers.get_content_length(headers) do
      {:ok, content_length} -> content_length
      {:error, reason} -> stream_error!(reason)
    end
  end

  # Per RFC9113§8.2.3
  defp combine_cookie_crumbs(headers) do
    {crumbs, other_headers} = headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)
    combined_cookie = Enum.map_join(crumbs, "; ", fn {"cookie", crumb} -> crumb end)
    [{"cookie", combined_cookie} | other_headers]
  end

  def read_body(%__MODULE__{} = stream_transport, remaining_length, timeout, acc \\ []) do
    receive do
      {:data, data} ->
        {new_window, increment} =
          Bandit.HTTP2.FlowControl.compute_recv_window(
            stream_transport.recv_window_size,
            byte_size(data)
          )

        if increment > 0,
          do: call(stream_transport, {:send_recv_window_update, increment})

        stream_transport = %{stream_transport | recv_window_size: new_window}

        acc = [data | acc]
        remaining_length = remaining_length - byte_size(data)

        if remaining_length >= 0 do
          read_body(stream_transport, remaining_length, timeout, acc)
        else
          {:more, finalize_body(acc), calc_bytes_remaining(acc, stream_transport)}
        end

      :end_stream ->
        stream_transport = calc_bytes_remaining(acc, stream_transport)

        if stream_transport.bytes_remaining in [nil, 0] do
          {:ok, finalize_body(acc), stream_transport}
        else
          stream_error!("Got end_stream with #{stream_transport.bytes_remaining} byte(s) pending")
        end
    after
      timeout -> {:more, finalize_body(acc), calc_bytes_remaining(acc, stream_transport)}
    end
  end

  defp calc_bytes_remaining(data, stream_transport) do
    bytes_read = IO.iodata_length(data)

    bytes_remaining =
      case stream_transport.bytes_remaining do
        nil -> nil
        bytes_remaining -> bytes_remaining - bytes_read
      end

    %{stream_transport | bytes_remaining: bytes_remaining}
  end

  defp finalize_body(data) do
    data |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def send_headers(%__MODULE__{} = stream_transport, headers, end_stream) do
    call(stream_transport, {:send_headers, headers, end_stream})
  end

  def send_data(%__MODULE__{} = stream_transport, data, end_stream, bytes_sent \\ 0) do
    stream_transport = wait_for_send_window(stream_transport, 0)
    max_bytes_to_send = max(stream_transport.send_window_size, 0)
    {data_to_send, bytes_to_send, rest} = split_data(data, max_bytes_to_send)

    stream_transport =
      if end_stream || bytes_to_send > 0 do
        end_stream_to_send = end_stream && byte_size(rest) == 0
        call(stream_transport, {:send_data, data_to_send, end_stream_to_send}, :infinity)
        %{stream_transport | send_window_size: stream_transport.send_window_size - bytes_to_send}
      else
        stream_transport
      end

    if byte_size(rest) == 0 do
      {stream_transport, bytes_sent + bytes_to_send}
    else
      stream_transport = wait_for_send_window(stream_transport, :infinity)
      send_data(stream_transport, rest, end_stream, bytes_sent + bytes_to_send)
    end
  end

  defp wait_for_send_window(stream_transport, timeout) do
    receive do
      {:send_window_update, increment} ->
        case Bandit.HTTP2.FlowControl.update_send_window(
               stream_transport.send_window_size,
               increment
             ) do
          {:ok, new_window} ->
            %{stream_transport | send_window_size: new_window}

          {:error, reason} ->
            stream_error!(reason, error_code: Bandit.HTTP2.Errors.flow_control_error())
        end
    after
      timeout -> stream_transport
    end
  end

  defp split_data(data, desired_length) do
    data_length = IO.iodata_length(data)

    if data_length <= desired_length do
      {data, data_length, <<>>}
    else
      <<to_send::binary-size(desired_length), rest::binary>> = IO.iodata_to_binary(data)
      {to_send, desired_length, rest}
    end
  end

  def send_rst_stream(%__MODULE__{} = stream_transport, error_code) do
    call(stream_transport, {:send_rst_stream, error_code})
  end

  def send_shutdown_connection(%__MODULE__{} = stream_transport, error_code, msg) do
    call(stream_transport, {:shutdown_connection, error_code, msg})
  end

  defp call(stream_transport, msg, timeout \\ 5000) do
    GenServer.call(stream_transport.connection_pid, {msg, stream_transport.stream_id}, timeout)
  end

  @dialyzer {:nowarn_function, stream_error!: 1}
  @spec stream_error!(term(), keyword()) :: no_return()
  defp stream_error!(message, context \\ []) do
    raise Bandit.HTTP2.Errors.StreamError, Keyword.merge(context, message: message)
  end

  @dialyzer {:nowarn_function, connection_error!: 1}
  @spec connection_error!(term(), keyword()) :: no_return()
  defp connection_error!(message, context \\ []) do
    raise Bandit.HTTP2.Errors.ConnectionError, Keyword.merge(context, message: message)
  end
end
