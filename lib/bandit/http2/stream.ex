defmodule Bandit.HTTP2.Stream do
  @moduledoc false
  # Represents the state of an HTTP/2 stream, in a process-free manner. An instance of this
  # struct is maintained as the state of a `Bandit.HTTP2.StreamProcess` process, and it moves an HTTP/2
  # stream through its lifecycle by calling functions defined on this module. This state is also
  # tracked within the `Bandit.HTTP2.Adapter` instance that backs Bandit's Plug API.

  # Functions on this module are also called internally by the `Bandit.HTTP2.Connection` within
  # which this stream is contained; these functions allow the connection to pass messages into the
  # stream as they are received from the client. These functions all begin with `deliver_*` by
  # convention

  # The `recv_*` and `send_*` functions defined on this module are meant to be called by the
  # stream process itself. Within these functions, we purposefully use raw `receive` message
  # patterns in order to facilitate a blocking interface as required by `Plug.Conn.Adapter`.
  # This is unconventional (mostly since `Bandit.HTTP2.StreamProcess` is a `GenServer`), but also
  # safe since we're careful about the types of messages we accept, and the state that the stream
  # is in when we do so

  # We also use exceptions by convention here rather than error tuples since many
  # of these functions are called within Plug.Conn.Adapter calls, which makes it
  # difficult to properly unwind many error conditions back to a killed stream process
  # and a RstStream frame to the client. The pattern here is to raise exceptions,
  # and have the `Bandit.HTTP2.StreamProcess`'s `terminate/2` callback take care of calling back
  # into us via the `reset_stream/2` and `close_connection/2` functions here, with the luxury of
  # a nicely unwound stack and a process that is guaranteed to be terminated as soon as these
  # functions are called

  require Integer
  require Logger

  defstruct connection_pid: nil,
            stream_id: nil,
            state: :idle,
            recv_window_size: 65_535,
            send_window_size: nil,
            bytes_remaining: nil,
            transport_info: nil,
            read_timeout: 15_000

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "A handle to a stream, suitable for passing to the `deliver_*` functions on this module"
  @type stream_handle :: pid() | :closed

  @typedoc "An HTTP/2 stream state"
  @type state :: :idle | :open | :local_closed | :remote_closed | :closed

  @typedoc "The information necessary to communicate to/from a stream"
  @type t :: %__MODULE__{
          connection_pid: pid(),
          stream_id: non_neg_integer(),
          state: state(),
          recv_window_size: non_neg_integer(),
          send_window_size: non_neg_integer(),
          bytes_remaining: non_neg_integer() | nil,
          transport_info: Bandit.TransportInfo.t(),
          read_timeout: timeout()
        }

  def init(connection_pid, stream_id, initial_send_window_size, transport_info) do
    %__MODULE__{
      connection_pid: connection_pid,
      stream_id: stream_id,
      send_window_size: initial_send_window_size,
      transport_info: transport_info
    }
  end

  # Collection API - Delivery
  #
  # These functions are intended to be called by the connection process which contains this
  # stream. All of these start with `deliver_`

  @spec deliver_headers(stream_handle(), Plug.Conn.headers()) :: term()
  def deliver_headers(:closed, _headers), do: :ok
  def deliver_headers(pid, headers), do: send(pid, {:headers, headers})

  @spec deliver_data(stream_handle(), iodata()) :: term()
  def deliver_data(:closed, _data), do: :ok
  def deliver_data(pid, data), do: send(pid, {:data, data})

  @spec deliver_send_window_update(stream_handle(), non_neg_integer()) :: term()
  def deliver_send_window_update(:closed, _delta), do: :ok
  def deliver_send_window_update(pid, delta), do: send(pid, {:send_window_update, delta})

  @spec deliver_end_of_stream(stream_handle()) :: term()
  def deliver_end_of_stream(:closed), do: :ok
  def deliver_end_of_stream(pid), do: send(pid, :end_stream)

  @spec deliver_rst_stream(stream_handle(), Bandit.HTTP2.Errors.error_code()) :: term()
  def deliver_rst_stream(:closed, _error_code), do: :ok
  def deliver_rst_stream(pid, error_code), do: send(pid, {:rst_stream, error_code})

  # Stream API - Receiving

  def recv_headers(%__MODULE__{state: :idle} = stream) do
    case do_recv(stream, stream.read_timeout) do
      {:headers, headers, stream} ->
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
          stream = %{stream | bytes_remaining: content_length, state: :open}
          {:ok, method, request_target, headers, stream}
        rescue
          exception ->
            reraise %{exception | method: method, request_target: request_target}, __STACKTRACE__
        end

      :timeout ->
        stream_error!("Timed out waiting for HEADER")

      %__MODULE__{} = stream ->
        recv_headers(stream)
    end
  end

  defp build_request_target!(headers) do
    scheme = Bandit.Headers.get_header(headers, ":scheme")
    {host, port} = get_host_and_port!(headers)
    path = get_path!(headers)
    {scheme, host, port, path}
  end

  defp get_host_and_port!(headers) do
    case Bandit.Headers.get_header(headers, ":authority") do
      authority when not is_nil(authority) ->
        case Bandit.Headers.parse_hostlike_header(authority) do
          {:ok, host, port} -> {host, port}
          {:error, reason} -> stream_error!(reason)
        end

      nil ->
        {nil, nil}
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
    if Enum.count(headers, fn {key, _value} -> key == header end) != 1,
      do: stream_error!("Expected 1 #{header} headers")
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

  # RFC9113§8.2.3 - cookie headers may be split during transmission
  defp combine_cookie_crumbs(headers) do
    {crumbs, other_headers} = headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)
    combined_cookie = Enum.map_join(crumbs, "; ", fn {"cookie", crumb} -> crumb end)
    [{"cookie", combined_cookie} | other_headers]
  end

  def recv_body(stream, max_bytes_to_return, timeout, acc \\ [])

  def recv_body(%__MODULE__{state: state} = stream, max_bytes_to_return, timeout, acc)
      when state in [:open, :local_closed] do
    case do_recv(stream, timeout) do
      {:headers, trailers, stream} ->
        no_pseudo_headers!(trailers)
        Logger.warning("Ignoring trailers #{inspect(trailers)}")
        recv_body(stream, max_bytes_to_return, timeout, acc)

      {:data, data, stream} ->
        acc = [data | acc]
        max_bytes_to_return = max_bytes_to_return - byte_size(data)

        if max_bytes_to_return >= 0 do
          recv_body(stream, max_bytes_to_return, timeout, acc)
        else
          {:more, finalize_body(acc), stream}
        end

      {:end_stream, stream} ->
        {:ok, finalize_body(acc), stream}

      :timeout ->
        {:more, finalize_body(acc), stream}

      %__MODULE__{} = stream ->
        recv_body(stream, max_bytes_to_return, timeout, acc)
    end
  end

  def recv_body(%__MODULE__{state: :remote_closed} = stream, _max_bytes_to_return, _timeout, acc) do
    {:ok, finalize_body(acc), stream}
  end

  defp finalize_body(data), do: data |> Enum.reverse() |> IO.iodata_to_binary()

  defp no_pseudo_headers!(headers) do
    if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
      do: stream_error!("Received trailers with pseudo headers")
  end

  defp do_recv(%__MODULE__{state: :idle} = stream, timeout) do
    receive do
      {:headers, headers} -> {:headers, headers, %{stream | state: :open}}
      {:data, _data} -> connection_error!("Received DATA in idle state")
      :end_stream -> connection_error!("Received END_STREAM in idle state")
      {:send_window_update, _delta} -> connection_error!("Received WINDOW_UPDATE in idle state")
      {:rst_stream, _error_code} -> connection_error!("Received RST_STREAM in idle state")
    after
      timeout -> :timeout
    end
  end

  defp do_recv(%__MODULE__{state: state} = stream, timeout)
       when state in [:open, :local_closed] do
    receive do
      {:headers, headers} -> {:headers, headers, stream}
      {:data, data} -> {:data, data, do_recv_data(stream, data)}
      :end_stream -> {:end_stream, do_recv_end_stream(stream)}
      {:send_window_update, delta} -> do_recv_send_window_update(stream, delta)
      {:rst_stream, error_code} -> do_recv_rst_stream!(stream, error_code)
    after
      timeout -> :timeout
    end
  end

  defp do_recv(%__MODULE__{state: :remote_closed} = stream, timeout) do
    receive do
      {:headers, _headers} -> do_stream_closed_error!("Received HEADERS in remote_closed state")
      {:data, _data} -> do_stream_closed_error!("Received DATA in remote_closed state")
      :end_stream -> raise do_stream_closed_error!("Received END_STREAM in remote_closed state")
      {:send_window_update, delta} -> do_recv_send_window_update(stream, delta)
      {:rst_stream, error_code} -> do_recv_rst_stream!(stream, error_code)
    after
      timeout -> :timeout
    end
  end

  defp do_recv(%__MODULE__{state: :closed} = stream, timeout) do
    receive do
      {:headers, _headers} -> stream
      {:data, _data} -> stream
      :end_stream -> stream
      {:send_window_update, _delta} -> stream
      {:rst_stream, _error_code} -> stream
    after
      timeout -> :timeout
    end
  end

  defp do_recv_data(stream, data) do
    {new_window, increment} =
      Bandit.HTTP2.FlowControl.compute_recv_window(stream.recv_window_size, byte_size(data))

    if increment > 0, do: do_send(stream, {:send_recv_window_update, increment})

    bytes_remaining =
      case stream.bytes_remaining do
        nil -> nil
        bytes_remaining -> bytes_remaining - byte_size(data)
      end

    %{stream | recv_window_size: new_window, bytes_remaining: bytes_remaining}
  end

  defp do_recv_end_stream(stream) do
    next_state =
      case stream.state do
        :open -> :remote_closed
        :local_closed -> :closed
      end

    if stream.bytes_remaining not in [nil, 0],
      do: stream_error!("Received END_STREAM with byte still pending!")

    %{stream | state: next_state}
  end

  defp do_recv_send_window_update(stream, delta) do
    case Bandit.HTTP2.FlowControl.update_send_window(stream.send_window_size, delta) do
      {:ok, new_window} -> %{stream | send_window_size: new_window}
      {:error, reason} -> stream_error!(reason, Bandit.HTTP2.Errors.flow_control_error())
    end
  end

  @spec do_recv_rst_stream!(term(), term()) :: no_return()
  defp do_recv_rst_stream!(_stream, error_code),
    do: raise("Client sent RST_STREAM with error code #{error_code}")

  @spec do_stream_closed_error!(term()) :: no_return()
  defp do_stream_closed_error!(msg), do: stream_error!(msg, Bandit.HTTP2.Errors.stream_closed())

  # Stream API - Sending

  def send_headers(%__MODULE__{state: state} = stream, headers, end_stream)
      when state in [:open, :remote_closed] do
    do_send(stream, {:send_headers, headers, end_stream})
    set_state_on_send_end_stream(stream, end_stream)
  end

  def send_data(%__MODULE__{state: state} = stream, data, end_stream, bytes_sent \\ 0)
      when state in [:open, :remote_closed] do
    stream =
      receive do
        {:send_window_update, delta} -> do_recv_send_window_update(stream, delta)
      after
        0 -> stream
      end

    max_bytes_to_send = max(stream.send_window_size, 0)
    {data_to_send, bytes_to_send, rest} = split_data(data, max_bytes_to_send)

    stream =
      if end_stream || bytes_to_send > 0 do
        end_stream_to_send = end_stream && byte_size(rest) == 0
        call(stream, {:send_data, data_to_send, end_stream_to_send}, :infinity)
        %{stream | send_window_size: stream.send_window_size - bytes_to_send}
      else
        stream
      end

    bytes_sent = bytes_sent + bytes_to_send

    if byte_size(rest) == 0 do
      {bytes_sent, set_state_on_send_end_stream(stream, end_stream)}
    else
      receive do
        {:send_window_update, delta} ->
          stream
          |> do_recv_send_window_update(delta)
          |> send_data(rest, end_stream, bytes_sent)
      after
        stream.read_timeout -> raise "Timeout waiting for space in the send_window"
      end
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

  defp set_state_on_send_end_stream(stream, false), do: stream

  defp set_state_on_send_end_stream(%__MODULE__{state: :open} = stream, true),
    do: %{stream | state: :local_closed}

  defp set_state_on_send_end_stream(%__MODULE__{state: :remote_closed} = stream, true),
    do: %{stream | state: :closed}

  # Closing off the stream upon completion or error

  def ensure_completed(%__MODULE__{state: :closed} = stream), do: stream

  def ensure_completed(%__MODULE__{state: :local_closed} = stream) do
    receive do
      :end_stream -> do_recv_end_stream(stream)
    after
      # RFC9113§8.1 - hint the client to stop sending data
      0 -> reset_stream(stream, Bandit.HTTP2.Errors.no_error())
    end
  end

  def ensure_completed(%__MODULE__{state: state}) do
    stream_error!("Terminating stream in #{state} state", Bandit.HTTP2.Errors.internal_error())
  end

  def reset_stream(%__MODULE__{state: :closed} = stream, _error_code), do: stream

  def reset_stream(%__MODULE__{} = stream, error_code) do
    do_send(stream, {:send_rst_stream, error_code})
    %{stream | state: :closed}
  end

  def close_connection(%__MODULE__{} = stream, error_code, msg),
    do: do_send(stream, {:shutdown_connection, error_code, msg})

  # Helpers

  defp do_send(stream, msg), do: send(stream.connection_pid, {msg, stream.stream_id})

  defp call(stream, msg, timeout),
    do: GenServer.call(stream.connection_pid, {msg, stream.stream_id}, timeout)

  @spec stream_error!(term()) :: no_return()
  @spec stream_error!(term(), Bandit.HTTP2.Errors.error_code()) :: no_return()
  defp stream_error!(message, error_code \\ Bandit.HTTP2.Errors.protocol_error()),
    do: raise(Bandit.HTTP2.Errors.StreamError, message: message, error_code: error_code)

  @spec connection_error!(term()) :: no_return()
  @spec connection_error!(term(), Bandit.HTTP2.Errors.error_code()) :: no_return()
  defp connection_error!(message, error_code \\ Bandit.HTTP2.Errors.protocol_error()),
    do: raise(Bandit.HTTP2.Errors.ConnectionError, message: message, error_code: error_code)
end
