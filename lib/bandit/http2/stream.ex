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

  require Logger

  defstruct connection_pid: nil,
            stream_id: nil,
            state: :idle,
            recv_window_size: 65_535,
            recv_window_target: 65_535,
            send_window_size: nil,
            sendfile_chunk_size: nil,
            bytes_remaining: nil,
            pending_headers: nil,
            consumed_messages: 0,
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
          recv_window_size: integer(),
          recv_window_target: pos_integer(),
          send_window_size: non_neg_integer(),
          sendfile_chunk_size: pos_integer(),
          bytes_remaining: non_neg_integer() | nil,
          pending_headers: nil | Plug.Conn.headers(),
          consumed_messages: non_neg_integer(),
          read_timeout: timeout()
        }

  def init(
        connection_pid,
        stream_id,
        initial_send_window_size,
        initial_recv_window_size,
        sendfile_chunk_size
      ) do
    %__MODULE__{
      connection_pid: connection_pid,
      stream_id: stream_id,
      send_window_size: initial_send_window_size,
      recv_window_size: initial_recv_window_size,
      recv_window_target:
        Bandit.HTTP2.FlowControl.stream_recv_window_target(initial_recv_window_size),
      sendfile_chunk_size: sendfile_chunk_size
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

  @spec deliver_data(stream_handle(), iodata(), non_neg_integer(), boolean()) :: term()
  def deliver_data(:closed, _data, _padding, _end_stream), do: :ok

  def deliver_data(pid, data, padding, end_stream),
    do: send(pid, {:bandit, {:data, data, padding, end_stream}})

  @spec deliver_send_window_update(stream_handle(), non_neg_integer()) :: term()
  def deliver_send_window_update(:closed, _delta), do: :ok

  def deliver_send_window_update(pid, delta),
    do: send(pid, {:bandit, {:send_window_update, delta}})

  @spec deliver_rst_stream(stream_handle(), Bandit.HTTP2.Errors.error_code()) :: term()
  def deliver_rst_stream(:closed, _error_code), do: :ok
  def deliver_rst_stream(pid, error_code), do: send(pid, {:bandit, {:rst_stream, error_code}})

  defimpl Bandit.HTTPTransport do
    # How many messages we consume from the connection between reports back to it. See
    # `Bandit.HTTP2.Connection`'s `@max_queued_stream_messages`
    @consumed_messages_report_interval 16

    def peer_data(%@for{} = stream), do: call(stream, :peer_data, :infinity)

    def sock_data(%@for{} = stream), do: call(stream, :sock_data, :infinity)

    def ssl_data(%@for{} = stream), do: call(stream, :ssl_data, :infinity)

    def version(%@for{}), do: :"HTTP/2"

    def read_headers(%@for{state: :idle} = stream) do
      case do_recv(stream, stream.read_timeout) do
        {:headers, headers, stream} ->
          method = Bandit.Headers.get_header(headers, ":method")
          {pseudo_headers, headers} = split_headers!(headers, stream)
          pseudo_headers_all_request!(pseudo_headers, stream)
          headers_all_lowercase!(headers, stream)
          valid_field_values!(pseudo_headers ++ headers, stream)
          request_target = build_request_target!(pseudo_headers, stream)
          exactly_one_instance_of!(pseudo_headers, ":scheme", stream)
          exactly_one_instance_of!(pseudo_headers, ":method", stream)
          exactly_one_instance_of!(pseudo_headers, ":path", stream)
          at_most_one_instance_of!(pseudo_headers, ":authority", stream)
          at_most_one_instance_of!(headers, "host", stream)
          host_matches_authority!(headers, request_target, stream)
          no_connection_headers!(headers, stream)
          valid_te_header!(headers, stream)
          content_length = get_content_length!(headers, stream)
          headers = combine_cookie_crumbs(headers)
          stream = %{stream | bytes_remaining: content_length}

          if stream.state in [:remote_closed, :closed] and content_length not in [nil, 0],
            do: stream_error!("Received END_STREAM with byte still pending", stream)

          {:ok, method, request_target, headers, stream}

        :timeout ->
          stream_error!("Timed out waiting for HEADER", stream)
      end
    end

    defp build_request_target!(headers, stream) do
      scheme = Bandit.Headers.get_header(headers, ":scheme")
      {host, port} = get_host_and_port!(headers, stream)
      path = get_path!(headers, stream)
      {scheme, host, port, path}
    end

    defp get_host_and_port!(headers, stream) do
      case Bandit.Headers.get_header(headers, ":authority") do
        authority when not is_nil(authority) -> Bandit.Headers.parse_hostlike_header!(authority)
        nil -> {nil, nil}
      end
    rescue
      _error in Bandit.HTTPError -> stream_error!("Received invalid :authority", stream)
    end

    # RFC9113§8.3.1 - host and :authority must agree. An absent port only matches
    # another absent port; do not substitute the scheme's default.
    defp host_matches_authority!(_headers, {_scheme, nil, _port, _path}, _stream), do: :ok

    defp host_matches_authority!(
           headers,
           {_scheme, authority_host, authority_port, _path},
           stream
         ) do
      case Bandit.Headers.get_header(headers, "host") do
        nil ->
          :ok

        host_header ->
          {host, port} = Bandit.Headers.parse_hostlike_header!(host_header)

          if String.downcase(host, :ascii) != String.downcase(authority_host, :ascii) or
               port != authority_port,
             do: stream_error!("Host header differs from :authority (RFC9113§8.3.1)", stream)
      end
    rescue
      _error in Bandit.HTTPError -> stream_error!("Received invalid host header", stream)
    end

    # RFC9113§8.3.1 - path should be non-empty and absolute
    defp get_path!(headers, stream) do
      headers
      |> Bandit.Headers.get_header(":path")
      |> case do
        nil -> stream_error!("Received empty :path", stream)
        "*" -> :*
        "/" <> _ = path -> path
        _ -> stream_error!("Path does not start with /", stream)
      end
    end

    # RFC9113§8.3 - pseudo headers must appear first
    defp split_headers!(headers, stream) do
      {pseudo_headers, headers} =
        Enum.split_while(headers, fn {key, _value} -> String.starts_with?(key, ":") end)

      if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
        do: stream_error!("Received pseudo headers after regular one", stream),
        else: {pseudo_headers, headers}
    end

    # RFC9113§8.3.1 - only request pseudo headers may appear
    defp pseudo_headers_all_request!(headers, stream) do
      if Enum.any?(headers, fn {key, _value} ->
           key not in ~w[:method :scheme :authority :path]
         end),
         do: stream_error!("Received invalid pseudo header", stream)
    end

    # RFC9113§8.3.1 - method, scheme, path pseudo headers must appear exactly once
    defp exactly_one_instance_of!(headers, header, stream) do
      if Enum.count(headers, fn {key, _value} -> key == header end) != 1,
        do: stream_error!("Expected 1 #{header} headers", stream)
    end

    # RFC9113§8.3 / RFC9110§7.2 - :authority and host are optional, but must not
    # appear more than once
    defp at_most_one_instance_of!(headers, header, stream) do
      if Enum.count(headers, fn {key, _value} -> key == header end) > 1,
        do: stream_error!("Expected at most 1 #{header} headers", stream)
    end

    # RFC9110§5.1 defines a field name as a non-empty token, and RFC9113§8.2.1 additionally
    # prohibits uppercase characters in HTTP/2 field names. Check uppercase first so that the
    # more specific existing diagnostic is preserved.
    defp headers_all_lowercase!(headers, stream) do
      cond do
        Enum.any?(headers, fn {key, _value} -> not lowercase?(key) end) ->
          stream_error!("Received uppercase header", stream)

        Enum.any?(headers, fn {key, _value} -> not valid_field_name?(key) end) ->
          stream_error!("Received invalid header field name (RFC9113§8.2.1)", stream)

        true ->
          :ok
      end
    end

    defp lowercase?(<<char, _rest::bits>>) when char >= ?A and char <= ?Z, do: false
    defp lowercase?(<<_char, rest::bits>>), do: lowercase?(rest)
    defp lowercase?(<<>>), do: true

    defp valid_field_name?(<<>>), do: false
    defp valid_field_name?(name), do: valid_field_name_bytes?(name)

    defp valid_field_name_bytes?(<<char, rest::binary>>)
         when char in ?a..?z or char in ?0..?9 or char in ~c"!#$%&'*+-.^_`|~",
         do: valid_field_name_bytes?(rest)

    defp valid_field_name_bytes?(<<_char, _rest::binary>>), do: false
    defp valid_field_name_bytes?(<<>>), do: true

    # RFC9113§8.2.2 - no hop-by-hop headers
    # Note that we do not filter out the TE header here, since it is allowed in
    # specific cases by RFC9113§8.2.2. We check those cases in a separate filter
    defp no_connection_headers!(headers, stream) do
      connection_headers =
        ~w[connection keep-alive proxy-connection transfer-encoding upgrade]

      if Enum.any?(headers, fn {key, _value} -> key in connection_headers end),
        do: stream_error!("Received connection-specific header", stream)
    end

    # RFC9113§8.2.2 - TE header may be present if it contains exactly 'trailers'
    defp valid_te_header!(headers, stream) do
      invalid? =
        headers
        |> Enum.filter(fn {name, _value} -> name == "te" end)
        |> Enum.any?(fn {"te", value} ->
          case Plug.Conn.Utils.list(value) do
            [] -> true
            members -> Enum.any?(members, &(String.downcase(&1, :ascii) != "trailers"))
          end
        end)

      if invalid?,
        do: stream_error!("Received invalid TE header", stream)
    end

    # RFC9113§8.2.1 - field values containing CR, LF, or NUL characters, or beginning or
    # ending with SP or HTAB, are malformed.
    defp valid_field_values!(headers, stream) do
      if Enum.any?(headers, fn {_key, value} -> not valid_field_value?(value) end),
        do: stream_error!("Field value contains invalid characters (RFC9113§8.2.1)", stream)
    end

    defp valid_field_value?(<<>>), do: true

    defp valid_field_value?(value) do
      Bandit.Headers.field_value_valid?(value) and
        :binary.first(value) not in [0x09, 0x20] and
        :binary.last(value) not in [0x09, 0x20]
    end

    defp get_content_length!(headers, stream) do
      case Bandit.Headers.get_content_length(headers) do
        {:ok, content_length} -> content_length
        {:error, reason} -> stream_error!(reason, stream)
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

      deadline =
        if timeout == :infinity, do: :infinity, else: now() + timeout

      do_read_data(stream, max_bytes, timeout, deadline, <<>>)
    end

    # `deadline` bounds this whole read. Like the send-side deadlines, it is only pushed back in
    # proportion to the data the peer actually delivers, so that frames which deliver nothing
    # (WINDOW_UPDATE, empty SETTINGS, PING) or a mere trickle of data cannot keep the read going
    # forever. See `Bandit.HTTP2.FlowControl.extend_send_deadline/4`
    defp do_read_data(%@for{state: state} = stream, max_bytes, timeout, deadline, acc)
         when state in [:open, :local_closed] do
      case do_recv(stream, remaining(deadline)) do
        {:headers, trailers, stream} ->
          Logger.warning("Ignoring trailers #{inspect(trailers)}", domain: [:bandit])
          do_read_data(stream, max_bytes, timeout, deadline, acc)

        {:data, data, stream} ->
          # Append the payload to a binary rather than keeping each DATA frame as its own list
          # cell. The `:length` option bounds the bytes in a body, not the frames they arrive in; an
          # iolist uses a list cell and a binary term per frame, so a body sent as one-byte DATA
          # frames would use many times its own size. A frame at least as large as the body so far
          # is joined to it with one copy of both, which costs no more than appending, and avoids
          # growing the body several times over (as `do_read_next_chunk!` does for HTTP/1).
          acc =
            if byte_size(data) >= byte_size(acc),
              do: IO.iodata_to_binary([acc, data]),
              else: <<acc::binary, data::binary>>

          max_bytes = max_bytes - byte_size(data)

          deadline =
            if deadline == :infinity,
              do: :infinity,
              else:
                Bandit.HTTP2.FlowControl.extend_send_deadline(
                  deadline,
                  byte_size(data),
                  now(),
                  timeout
                )

          # Stop as soon as `length` bytes have been read, as HTTP/1 does, instead of waiting for
          # more data until the read times out. A stream whose remote end has closed has nothing
          # left to wait for, so it falls through to the clause below and reports `:ok`.
          #
          # A body that is exactly `length` bytes long may still be missing its END_STREAM (an
          # empty DATA frame or a trailers HEADERS frame can carry it). If `content-length` tells
          # us the body is complete (`bytes_remaining == 0`), we wait for that END_STREAM, since a
          # compliant client sends it right away. Without a `content-length` we cannot know the
          # body is complete without waiting, and waiting is the bug this guards against, so we
          # return `:more` there, even if END_STREAM turns out to arrive in a separate frame.
          if max_bytes > 0 or
               (max_bytes == 0 and (stream.state == :remote_closed or stream.bytes_remaining == 0)) do
            do_read_data(stream, max_bytes, timeout, deadline, acc)
          else
            {:more, acc, stream}
          end

        :timeout ->
          {:more, acc, stream}

        %@for{} = stream ->
          do_read_data(stream, max_bytes, timeout, deadline, acc)
      end
    end

    defp do_read_data(%@for{state: :remote_closed} = stream, _max_bytes, _timeout, _deadline, acc) do
      {:ok, acc, stream}
    end

    defp now, do: :erlang.monotonic_time(:millisecond)

    defp remaining(:infinity), do: :infinity
    defp remaining(deadline), do: max(deadline - now(), 0)

    defp no_pseudo_headers!(headers, stream) do
      if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end),
        do: stream_error!("Received trailers with pseudo headers", stream)
    end

    defp validate_trailers!(_headers, false, stream) do
      stream_error!("Received trailers without END_STREAM", stream)
    end

    # RFC9113§8.1 - a trailer field section terminates the stream and is subject
    # to the same field-name and field-value requirements as other field sections
    defp validate_trailers!(headers, true, stream) do
      no_pseudo_headers!(headers, stream)
      headers_all_lowercase!(headers, stream)
      valid_trailer_field_names!(headers, stream)
      no_connection_headers!(headers, stream)
      valid_te_header!(headers, stream)
      valid_field_values!(headers, stream)
      valid_trailer_edge_whitespace!(headers, stream)
    end

    defp valid_trailer_field_names!(headers, stream) do
      if Enum.any?(headers, fn {key, _value} -> not valid_trailer_field_name?(key) end),
        do: stream_error!("Received invalid trailer field name (RFC9113§8.2.1)", stream)
    end

    defp valid_trailer_field_name?(<<>>), do: false
    defp valid_trailer_field_name?(name), do: valid_trailer_field_name_bytes?(name)

    defp valid_trailer_field_name_bytes?(<<char, rest::binary>>)
         when char in ?a..?z or char in ?0..?9 or char in ~c"!#$%&'*+-.^_`|~",
         do: valid_trailer_field_name_bytes?(rest)

    defp valid_trailer_field_name_bytes?(<<_char, _rest::binary>>), do: false
    defp valid_trailer_field_name_bytes?(<<>>), do: true

    defp valid_trailer_edge_whitespace!(headers, stream) do
      if Enum.any?(headers, fn
           {_key, <<>>} ->
             false

           {_key, value} ->
             :binary.first(value) in [0x09, 0x20] or :binary.last(value) in [0x09, 0x20]
         end),
         do: stream_error!("Field value contains invalid characters (RFC9113§8.2.1)", stream)
    end

    # The connection may be holding DATA back until we catch up on the messages it has sent us, so
    # before we block waiting on it we let it know what we have consumed
    defp do_recv(stream, timeout) do
      receive do
        {:bandit, message} -> do_recv_message(stream, message)
      after
        0 ->
          stream = report_consumed(stream)

          receive do
            {:bandit, message} -> do_recv_message(stream, message)
          after
            timeout -> :timeout
          end
      end
    end

    defp do_recv_message(%@for{state: :idle} = stream, message) do
      case message do
        {:headers, headers, end_stream} ->
          {:headers, headers,
           stream |> consumed() |> do_recv_headers() |> do_recv_end_stream(end_stream)}

        {:data, _data, _padding, _end_stream} ->
          connection_error!("Received DATA in idle state")

        {:send_window_update, _delta} ->
          connection_error!("Received WINDOW_UPDATE in idle state")

        {:rst_stream, _error_code} ->
          connection_error!("Received RST_STREAM in idle state")
      end
    end

    defp do_recv_message(%@for{state: state} = stream, message)
         when state in [:open, :local_closed] do
      case message do
        {:headers, headers, end_stream} ->
          validate_trailers!(headers, end_stream, stream)

          {:headers, headers,
           stream |> consumed() |> do_recv_headers() |> do_recv_end_stream(end_stream)}

        {:data, data, padding, end_stream} ->
          {:data, data,
           stream
           |> consumed()
           |> do_recv_data(data, padding, end_stream)
           |> do_recv_end_stream(end_stream)}

        {:send_window_update, delta} ->
          stream |> consumed() |> do_recv_send_window_update(delta)

        {:rst_stream, error_code} ->
          do_recv_rst_stream!(stream, error_code)
      end
    end

    defp do_recv_headers(%@for{state: :idle} = stream), do: %{stream | state: :open}
    defp do_recv_headers(stream), do: stream

    # Padding counts toward flow control, so it is given back to the peer along with the data
    defp do_recv_data(stream, data, padding, end_stream) do
      {new_window, increment} =
        Bandit.HTTP2.FlowControl.compute_recv_window(
          stream.recv_window_size,
          byte_size(data) + padding,
          stream.recv_window_target
        )

      if increment > 0 && !end_stream, do: do_send(stream, {:send_recv_window_update, increment})

      bytes_remaining =
        case stream.bytes_remaining do
          nil -> nil
          bytes_remaining -> bytes_remaining - byte_size(data)
        end

      %{stream | recv_window_size: new_window, bytes_remaining: bytes_remaining}
    end

    # Lets the connection know (every so often) how many of its messages we have consumed
    defp consumed(stream) do
      stream = %{stream | consumed_messages: stream.consumed_messages + 1}

      if stream.consumed_messages >= @consumed_messages_report_interval,
        do: report_consumed(stream),
        else: stream
    end

    defp report_consumed(%@for{consumed_messages: 0} = stream), do: stream

    defp report_consumed(stream) do
      do_send(stream, {:messages_consumed, stream.consumed_messages})
      %{stream | consumed_messages: 0}
    end

    defp do_recv_end_stream(stream, false), do: stream

    defp do_recv_end_stream(stream, true) do
      next_state =
        case stream.state do
          :open -> :remote_closed
          :local_closed -> :closed
        end

      if stream.bytes_remaining not in [nil, 0],
        do: stream_error!("Received END_STREAM with byte still pending", stream)

      %{stream | state: next_state}
    end

    defp do_recv_send_window_update(stream, delta) do
      case Bandit.HTTP2.FlowControl.update_send_window(stream.send_window_size, delta) do
        {:ok, new_window} ->
          %{stream | send_window_size: new_window}

        {:error, reason} ->
          stream_error!(reason, stream, Bandit.HTTP2.Errors.flow_control_error())
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

    # Stream API - Sending

    # `:raw` always precedes a body (via send_data/sendfile), so buffer the headers and let
    # send_data flush them with the first DATA frame in a single write (cf. HTTP/1 send_buffer).
    def send_headers(%@for{state: state} = stream, status, headers, :raw)
        when state in [:open, :remote_closed] do
      headers = [{":status", to_string(status)} | prepare_headers(headers)]
      %{stream | pending_headers: headers}
    end

    def send_headers(%@for{state: state} = stream, status, headers, body_disposition)
        when state in [:open, :remote_closed] do
      # We need to map body_disposition into the state model of HTTP/2. This turns out to be really
      # easy, since HTTP/2 only has one way to send data. The only bit we need from the disposition
      # is whether there will be any data forthcoming (ie: whether or not to end the stream). That
      # will possibly walk us to a different state per RFC9113§5.1, as determined by the tail call
      # to set_state_on_send_end_stream/2
      end_stream = body_disposition == :no_body
      headers = [{":status", to_string(status)} | prepare_headers(headers)]
      do_send(stream, {:send_headers, headers, end_stream})
      set_state_on_send_end_stream(stream, end_stream)
    end

    # RFC9113§8.2.2 - connection-specific header fields must not be sent in an HTTP/2 message, and
    # a peer MUST treat a message that contains one as malformed. The Plug API is protocol-agnostic,
    # so a plug may well set one of these for the benefit of HTTP/1 clients without knowing that it
    # is answering over HTTP/2; drop them here rather than let the client reset the stream
    @connection_specific_headers ~w[connection keep-alive proxy-connection transfer-encoding upgrade]

    # RFC9113§8.2.3 - cookie headers may be split during transmission
    defp prepare_headers(headers) do
      headers
      |> Enum.flat_map(fn
        {"cookie", cookie} ->
          cookie |> String.split("; ") |> Enum.map(fn crumb -> {"cookie", crumb} end)

        {header, _value} when header in @connection_specific_headers ->
          []

        {header, value} ->
          [{header, value}]
      end)
    end

    def send_data(%@for{} = stream, data, end_stream),
      do: do_send_data(stream, data, end_stream, nil)

    # `deadline` bounds how long we will wait on the stream send window; it is nil until we first
    # have to wait, and is then extended only as the peer actually lets us send data (see
    # `Bandit.HTTP2.FlowControl.extend_send_deadline/4`) rather than being reset by every
    # window update, so that a trickle of window updates cannot keep us waiting indefinitely
    defp do_send_data(%@for{state: state} = stream, data, end_stream, deadline)
         when state in [:open, :remote_closed] do
      stream =
        receive do
          {:bandit, {:send_window_update, delta}} ->
            stream |> consumed() |> do_recv_send_window_update(delta)

          {:bandit, {:rst_stream, error_code}} ->
            do_recv_rst_stream!(stream, error_code)
        after
          0 -> stream
        end

      max_bytes_to_send = max(stream.send_window_size, 0)
      {data_to_send, bytes_to_send, rest} = split_data(data, max_bytes_to_send)
      end_stream_to_send = end_stream && byte_size(rest) == 0

      stream =
        if stream.pending_headers != nil or end_stream or bytes_to_send > 0 do
          headers = stream.pending_headers || []

          case call(stream, {:send_data, headers, data_to_send, end_stream_to_send}, :infinity) do
            :ok ->
              %{
                stream
                | pending_headers: nil,
                  send_window_size: stream.send_window_size - bytes_to_send
              }

            {:error, :timeout} ->
              stream_error!(
                "Timeout waiting for space in the connection send_window",
                stream,
                Bandit.HTTP2.Errors.flow_control_error()
              )

            {:error, {:rst_stream, error_code}} ->
              do_recv_rst_stream!(stream, error_code)
          end
        else
          stream
        end

      if byte_size(rest) == 0 do
        set_state_on_send_end_stream(stream, end_stream)
      else
        now = :erlang.monotonic_time(:millisecond)

        deadline =
          if deadline,
            do:
              Bandit.HTTP2.FlowControl.extend_send_deadline(
                deadline,
                bytes_to_send,
                now,
                stream.read_timeout
              ),
            else: now + stream.read_timeout

        receive do
          {:bandit, {:send_window_update, delta}} ->
            stream
            |> consumed()
            |> do_recv_send_window_update(delta)
            |> do_send_data(rest, end_stream, deadline)

          # Observe a client reset promptly rather than sitting blocked until read_timeout
          # (after which we would send an RST_STREAM of our own, which RFC9113§6.4 forbids
          # after receiving one). Mirrors the handling in do_recv/2
          {:bandit, {:rst_stream, error_code}} ->
            do_recv_rst_stream!(stream, error_code)
        after
          max(deadline - :erlang.monotonic_time(:millisecond), 0) ->
            stream_error!(
              "Timeout waiting for space in the send_window",
              stream,
              Bandit.HTTP2.Errors.flow_control_error()
            )
        end
      end
    end

    def sendfile(%@for{} = stream, path, offset, length) do
      case :file.open(path, [:raw, :binary]) do
        {:ok, fd} ->
          try do
            if length == 0 do
              send_data(stream, "", true)
            else
              sendfile_loop(stream, fd, offset, length, 0)
            end
          after
            :file.close(fd)
          end

        {:error, reason} ->
          raise "Error opening file for sendfile: #{inspect(reason)}"
      end
    end

    defp sendfile_loop(stream, _fd, _offset, length, sent) when sent >= length do
      stream
    end

    defp sendfile_loop(stream, fd, offset, length, sent) do
      read_size = min(length - sent, sendfile_chunk_size(stream))

      case :file.pread(fd, offset + sent, read_size) do
        {:ok, data} ->
          now_sent = byte_size(data)
          end_stream = sent + now_sent >= length
          stream = send_data(stream, data, end_stream)

          if end_stream do
            stream
          else
            sendfile_loop(stream, fd, offset, length, sent + now_sent)
          end

        :eof ->
          raise "Error reading file for sendfile: :eof"

        {:error, reason} ->
          raise "Error reading file for sendfile: #{inspect(reason)}"
      end
    end

    defp sendfile_chunk_size(%@for{sendfile_chunk_size: sendfile_chunk_size}) do
      max(sendfile_chunk_size, 1)
    end

    defp split_data(data, desired_length) do
      data_length = IO.iodata_length(data)

      if data_length <= desired_length do
        {data, data_length, <<>>}
      else
        <<to_send::binary-size(^desired_length), rest::binary>> = IO.iodata_to_binary(data)
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

    def ensure_completed(%@for{state: :local_closed} = stream),
      do: drain_request(stream, false)

    def ensure_completed(%@for{state: state} = stream) do
      stream_error!(
        "Terminating stream in #{state} state",
        stream,
        Bandit.HTTP2.Errors.internal_error()
      )
    end

    # The connection may be holding back DATA for us (see `do_recv/2`). Before we decide that the
    # request is incomplete, report what we have consumed synchronously, so that any DATA it then
    # releases to us is already in our mailbox when the call returns
    defp drain_request(stream, synced?) do
      receive do
        {:bandit, {:headers, headers, end_stream}} ->
          validate_trailers!(headers, end_stream, stream)
          %{stream | state: :closed}

        {:bandit, {:data, data, padding, end_stream}} ->
          stream = stream |> consumed() |> do_recv_data(data, padding, end_stream)

          if end_stream do
            %{stream | state: :closed}
          else
            drain_request(stream, false)
          end
      after
        0 ->
          if synced? do
            # RFC9113§8.1 - hint the client to stop sending data
            do_send(stream, {:send_rst_stream, Bandit.HTTP2.Errors.no_error()})
          else
            :ok = call(stream, {:messages_consumed, stream.consumed_messages}, :infinity)
            drain_request(%{stream | consumed_messages: 0}, true)
          end
      end
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

    # A TransportError means the client reset the stream (do_recv_rst_stream!). RFC9113§6.4 forbids
    # sending any further frame except PRIORITY after receiving RST_STREAM, so send no response at
    # all -- not even an error one, unlike the generic clause below. Mirrors HTTP/1's handling.
    def send_on_error(%@for{} = stream, %Bandit.TransportError{}), do: %{stream | state: :closed}

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

    @spec stream_error!(String.t(), Bandit.HTTP2.Stream.t()) :: no_return()
    @spec stream_error!(
            String.t(),
            Bandit.HTTP2.Stream.t(),
            Bandit.HTTP2.Errors.error_code()
          ) :: no_return()
    defp stream_error!(message, stream, error_code \\ Bandit.HTTP2.Errors.protocol_error()),
      do:
        raise(Bandit.HTTP2.Errors.StreamError,
          message: message,
          error_code: error_code,
          stream_id: stream.stream_id
        )

    @spec connection_error!(term()) :: no_return()
    @spec connection_error!(term(), Bandit.HTTP2.Errors.error_code()) :: no_return()
    defp connection_error!(message, error_code \\ Bandit.HTTP2.Errors.protocol_error()),
      do: raise(Bandit.HTTP2.Errors.ConnectionError, message: message, error_code: error_code)
  end
end
