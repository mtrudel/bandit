defmodule Bandit.HTTP2.Stream do
  @moduledoc false
  # This module implements an HTTP/2 stream as described in RFC 9113, without concern for the higher-level
  # HTTP semantics described in RFC 9110. It is similar in spirit to `Bandit.HTTP1.Socket` for
  # HTTP/1, and indeed both implement the `Bandit.HTTPTransport` behaviour. An instance of this
  # struct is maintained as the state of a `Bandit.HTTP2.StreamProcess` process, and it moves an
  # HTTP/2 stream through its lifecycle by calling functions defined on this module. This state is
  # also tracked within the `Bandit.Adapter` instance that backs Bandit's Plug API.
  #
  # A note about naming:
  #
  # This module has several intended callers, and due to its nature as a coordinator, needs to be
  # careful about how it uses terms like 'read', 'send', 'receive', etc. To that end, there are
  # some conventions in place:
  #
  # * Functions on this module which are intended to be called internally by the containing
  #   `Bandit.HTTP2.Connection` to pass information received from the client (such as headers or
  #   request data) to this stream. These functions are named `deliver_*`, and are intended to be
  #   called by the connection process. As such, they take a `stream_handle()` argument, which
  #   corresponds either to a pid (in the case of an active stream), or the value `:closed` (in the
  #   case of a stream which has already completed processing)
  #
  # * Functions on this module which are intended to be called by the higher-level implementation
  #   that is processing this stream are implemented via the `Bandit.HTTPTransport` protocol
  #
  # * In order for this stream to receive information from the containing connection process, we
  #   use carefully crafted `receive` calls (we do this in a manner that is safe to do within a
  #   GenServer). This work is handled internally by a number of functions named `do_recv_*`, which
  #   generally present a blocking interface in order to align with the expectations of the
  #   `Plug.Conn.Adapter` behaviour.
  #
  # This module also uses exceptions by convention rather than error tuples since many
  # of these functions are called within `Plug.Conn.Adapter` calls, which makes it
  # difficult to properly unwind many error conditions back to a place where we can properly shut
  # down the stream by sending a RstStream frame to the client and terminating our process. The
  # pattern here is to raise exceptions, and have the `Bandit.HTTP2.StreamProcess`'s `terminate/2`
  # callback take care of calling back into us via the `reset_stream/2` and `close_connection/2`
  # functions here, with the luxury of a nicely unwound stack and a process that is guaranteed to
  # be terminated as soon as these functions are called

  require Integer
  require Logger

  defstruct connection_pid: nil,
            stream_id: nil,
            state: :idle,
            recv_window_size: 65_535,
            send_window_size: nil,
            bytes_remaining: nil,
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
          read_timeout: timeout()
        }

  def init(connection_pid, stream_id, initial_send_window_size) do
    %__MODULE__{
      connection_pid: connection_pid,
      stream_id: stream_id,
      send_window_size: initial_send_window_size
    }
  end

  # Collection API - Delivery
  #
  # These functions are intended to be called by the connection process which contains this
  # stream. All of these start with `deliver_`

  @spec deliver_headers(stream_handle(), Plug.Conn.headers(), boolean()) :: term()
  def deliver_headers(:closed, _headers, _end_stream), do: :ok

  def deliver_headers(pid, headers, end_stream),
    do: send(pid, {:bandit, {:headers, headers, end_stream}})

  @spec deliver_data(stream_handle(), iodata(), boolean()) :: term()
  def deliver_data(:closed, _data, _end_stream), do: :ok
  def deliver_data(pid, data, end_stream), do: send(pid, {:bandit, {:data, data, end_stream}})

  @spec deliver_send_window_update(stream_handle(), non_neg_integer()) :: term()
  def deliver_send_window_update(:closed, _delta), do: :ok

  def deliver_send_window_update(pid, delta),
    do: send(pid, {:bandit, {:send_window_update, delta}})

  @spec deliver_rst_stream(stream_handle(), Bandit.HTTP2.Errors.error_code()) :: term()
  def deliver_rst_stream(:closed, _error_code), do: :ok
  def deliver_rst_stream(pid, error_code), do: send(pid, {:bandit, {:rst_stream, error_code}})

  defimpl Bandit.HTTPTransport do
    def peer_data(%@for{} = stream), do: call(stream, :peer_data, :infinity)

    def sock_data(%@for{} = stream), do: call(stream, :sock_data, :infinity)

    def ssl_data(%@for{} = stream), do: call(stream, :ssl_data, :infinity)

    def version(%@for{}), do: :"HTTP/2"

    def read_headers(%@for{state: :idle} = stream) do
      case do_recv(stream, stream.read_timeout) do
        {:headers, headers, stream} ->
          method = Bandit.Headers.get_header(headers, ":method")
          request_target = build_request_target!(headers)
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
          stream = %{stream | bytes_remaining: content_length}
          {:ok, method, request_target, headers, stream}

        :timeout ->
          stream_error!("Timed out waiting for HEADER")

        %@for{} = stream ->
          read_headers(stream)
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
        authority when not is_nil(authority) -> Bandit.Headers.parse_hostlike_header!(authority)
        nil -> {nil, nil}
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
      if Enum.any?(headers, fn {key, _value} ->
           key not in ~w[:method :scheme :authority :path]
         end),
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
      {crumbs, other_headers} =
        headers |> Enum.split_with(fn {header, _} -> header == "cookie" end)

      case Enum.map_join(crumbs, "; ", fn {"cookie", crumb} -> crumb end) do
        "" -> other_headers
        combined_cookie -> [{"cookie", combined_cookie} | other_headers]
      end
    end

    def read_data(%@for{} = stream, opts) do
      max_bytes = Keyword.get(opts, :length, 8_000_000)
      timeout = Keyword.get(opts, :read_timeout, 15_000)
      do_read_data(stream, max_bytes, timeout, [])
    end

    defp do_read_data(%@for{state: state} = stream, max_bytes, timeout, acc)
         when state in [:open, :local_closed] do
      case do_recv(stream, timeout) do
        {:headers, trailers, stream} ->
          no_pseudo_headers!(trailers)
          Logger.warning("Ignoring trailers #{inspect(trailers)}", domain: [:bandit])
          do_read_data(stream, max_bytes, timeout, acc)

        {:data, data, stream} ->
          acc = [data | acc]
          max_bytes = max_bytes - byte_size(data)

          if max_bytes >= 0 do
            do_read_data(stream, max_bytes, timeout, acc)
          else
            {:more, Enum.reverse(acc), stream}
          end

        :timeout ->
          {:more, Enum.reverse(acc), stream}

        %@for{} = stream ->
          do_read_data(stream, max_bytes, timeout, acc)
      end
    end

    defp do_read_data(%@for{state: :remote_closed} = stream, _max_bytes, _timeout, acc) do
      {:ok, Enum.reverse(acc), stream}
    end

    defp no_pseudo_headers!(headers) do
      if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
        do: stream_error!("Received trailers with pseudo headers")
    end

    defp do_recv(%@for{state: :idle} = stream, timeout) do
      receive do
        {:bandit, {:headers, headers, end_stream}} ->
          {:headers, headers, stream |> do_recv_headers() |> do_recv_end_stream(end_stream)}

        {:bandit, {:data, _data, _end_stream}} ->
          connection_error!("Received DATA in idle state")

        {:bandit, {:send_window_update, _delta}} ->
          connection_error!("Received WINDOW_UPDATE in idle state")

        {:bandit, {:rst_stream, _error_code}} ->
          connection_error!("Received RST_STREAM in idle state")
      after
        timeout -> :timeout
      end
    end

    defp do_recv(%@for{state: state} = stream, timeout)
         when state in [:open, :local_closed] do
      receive do
        {:bandit, {:headers, headers, end_stream}} ->
          {:headers, headers, stream |> do_recv_headers() |> do_recv_end_stream(end_stream)}

        {:bandit, {:data, data, end_stream}} ->
          {:data, data,
           stream |> do_recv_data(data, end_stream) |> do_recv_end_stream(end_stream)}

        {:bandit, {:send_window_update, delta}} ->
          do_recv_send_window_update(stream, delta)

        {:bandit, {:rst_stream, error_code}} ->
          do_recv_rst_stream!(stream, error_code)
      after
        timeout -> :timeout
      end
    end

    defp do_recv(%@for{state: :remote_closed} = stream, timeout) do
      receive do
        {:bandit, {:headers, _headers, _end_stream}} ->
          do_stream_closed_error!("Received HEADERS in remote_closed state")

        {:bandit, {:data, _data, _end_stream}} ->
          do_stream_closed_error!("Received DATA in remote_closed state")

        {:bandit, {:send_window_update, delta}} ->
          do_recv_send_window_update(stream, delta)

        {:bandit, {:rst_stream, error_code}} ->
          do_recv_rst_stream!(stream, error_code)
      after
        timeout -> :timeout
      end
    end

    defp do_recv(%@for{state: :closed} = stream, timeout) do
      receive do
        {:bandit, {:headers, _headers, _end_stream}} -> stream
        {:bandit, {:data, _data, _end_stream}} -> stream
        {:bandit, {:send_window_update, _delta}} -> stream
        {:bandit, {:rst_stream, _error_code}} -> stream
      after
        timeout -> :timeout
      end
    end

    defp do_recv_headers(%@for{state: :idle} = stream), do: %{stream | state: :open}
    defp do_recv_headers(stream), do: stream

    defp do_recv_data(stream, data, end_stream) do
      {new_window, increment} =
        Bandit.HTTP2.FlowControl.compute_recv_window(stream.recv_window_size, byte_size(data))

      if increment > 0 && !end_stream, do: do_send(stream, {:send_recv_window_update, increment})

      bytes_remaining =
        case stream.bytes_remaining do
          nil -> nil
          bytes_remaining -> bytes_remaining - byte_size(data)
        end

      %{stream | recv_window_size: new_window, bytes_remaining: bytes_remaining}
    end

    defp do_recv_end_stream(stream, false), do: stream

    defp do_recv_end_stream(stream, true) do
      next_state =
        case stream.state do
          :open -> :remote_closed
          :local_closed -> :closed
        end

      if stream.bytes_remaining not in [nil, 0],
        do: stream_error!("Received END_STREAM with byte still pending")

      %{stream | state: next_state}
    end

    defp do_recv_send_window_update(stream, delta) do
      case Bandit.HTTP2.FlowControl.update_send_window(stream.send_window_size, delta) do
        {:ok, new_window} -> %{stream | send_window_size: new_window}
        {:error, reason} -> stream_error!(reason, Bandit.HTTP2.Errors.flow_control_error())
      end
    end

    @spec do_recv_rst_stream!(term(), term()) :: no_return()
    defp do_recv_rst_stream!(_stream, error_code) do
      case Bandit.HTTP2.Errors.to_reason(error_code) do
        reason when reason in [:no_error, :cancel] ->
          raise(Bandit.TransportError, message: "Client reset stream normally", error: :closed)

        reason ->
          raise(Bandit.TransportError,
            message: "Received RST_STREAM from client: #{reason} (#{error_code})",
            error: reason
          )
      end
    end

    @spec do_stream_closed_error!(term()) :: no_return()
    defp do_stream_closed_error!(msg), do: stream_error!(msg, Bandit.HTTP2.Errors.stream_closed())

    # Stream API - Sending

    def send_headers(%@for{state: state} = stream, status, headers, body_disposition)
        when state in [:open, :remote_closed] do
      # We need to map body_disposition into the state model of HTTP/2. This turns out to be really
      # easy, since HTTP/2 only has one way to send data. The only bit we need from the disposition
      # is whether there will be any data forthcoming (ie: whether or not to end the stream). That
      # will possibly walk us to a different state per RFC9113§5.1, as determined by the tail call
      # to set_state_on_send_end_stream/2
      end_stream = body_disposition == :no_body
      headers = [{":status", to_string(status)} | split_cookies(headers)]
      do_send(stream, {:send_headers, headers, end_stream})
      set_state_on_send_end_stream(stream, end_stream)
    end

    # RFC9113§8.2.3 - cookie headers may be split during transmission
    defp split_cookies(headers) do
      headers
      |> Enum.flat_map(fn
        {"cookie", cookie} ->
          cookie |> String.split("; ") |> Enum.map(fn crumb -> {"cookie", crumb} end)

        {header, value} ->
          [{header, value}]
      end)
    end

    def send_data(%@for{state: state} = stream, data, end_stream)
        when state in [:open, :remote_closed] do
      stream =
        receive do
          {:bandit, {:send_window_update, delta}} -> do_recv_send_window_update(stream, delta)
          {:bandit, {:rst_stream, error_code}} -> do_recv_rst_stream!(stream, error_code)
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

      if byte_size(rest) == 0 do
        set_state_on_send_end_stream(stream, end_stream)
      else
        receive do
          {:bandit, {:send_window_update, delta}} ->
            stream
            |> do_recv_send_window_update(delta)
            |> send_data(rest, end_stream)
        after
          stream.read_timeout ->
            stream_error!(
              "Timeout waiting for space in the send_window",
              Bandit.HTTP2.Errors.flow_control_error()
            )
        end
      end
    end

    def sendfile(%@for{} = stream, path, offset, length) do
      case :file.open(path, [:raw, :binary]) do
        {:ok, fd} ->
          try do
            case :file.pread(fd, offset, length) do
              {:ok, data} -> send_data(stream, data, true)
              {:error, reason} -> raise "Error reading file for sendfile: #{inspect(reason)}"
            end
          after
            :file.close(fd)
          end

        {:error, reason} ->
          raise "Error opening file for sendfile: #{inspect(reason)}"
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

    defp set_state_on_send_end_stream(%@for{state: :open} = stream, true),
      do: %{stream | state: :local_closed}

    defp set_state_on_send_end_stream(%@for{state: :remote_closed} = stream, true),
      do: %{stream | state: :closed}

    # Closing off the stream upon completion or error

    def ensure_completed(%@for{state: :closed} = stream), do: stream

    def ensure_completed(%@for{state: :local_closed} = stream) do
      receive do
        {:bandit, {:headers, _headers, true}} ->
          do_recv_end_stream(stream, true)

        {:bandit, {:data, data, true}} ->
          do_recv_data(stream, data, true) |> do_recv_end_stream(true)
      after
        # RFC9113§8.1 - hint the client to stop sending data
        0 -> do_send(stream, {:send_rst_stream, Bandit.HTTP2.Errors.no_error()})
      end
    end

    def ensure_completed(%@for{state: state}) do
      stream_error!("Terminating stream in #{state} state", Bandit.HTTP2.Errors.internal_error())
    end

    def supported_upgrade?(%@for{} = _stream, _protocol), do: false

    def send_on_error(%@for{} = stream, %Bandit.HTTP2.Errors.StreamError{} = error) do
      do_send(stream, {:send_rst_stream, error.error_code})
      %{stream | state: :closed}
    end

    def send_on_error(%@for{} = stream, %Bandit.HTTP2.Errors.ConnectionError{} = error) do
      do_send(stream, {:close_connection, error.error_code, error.message})
      stream
    end

    def send_on_error(%@for{state: state} = stream, error) when state in [:idle, :open] do
      stream = maybe_send_error(%{stream | state: :open}, error)
      %{stream | state: :local_closed}
    end

    def send_on_error(%@for{state: :remote_closed} = stream, error) do
      stream = maybe_send_error(%{stream | state: :open}, error)
      %{stream | state: :closed}
    end

    def send_on_error(%@for{} = stream, _error), do: stream

    defp maybe_send_error(stream, error) do
      receive do
        {:plug_conn, :sent} -> stream
      after
        0 ->
          status = error |> Plug.Exception.status() |> Plug.Conn.Status.code()
          send_headers(stream, status, [], :no_body)
      end
    end

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
end
