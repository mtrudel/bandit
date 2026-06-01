defmodule Bandit.HTTP1.Socket do
  @moduledoc false
  # This module implements the lower level parts of HTTP/1 (roughly, the aspects of the protocol
  # described in RFC 9112 as opposed to RFC 9110). It is similar in spirit to
  # `Bandit.HTTP2.Stream` for HTTP/2, and indeed both implement the `Bandit.HTTPTransport`
  # behaviour. An instance of this struct is maintained as the state of a `Bandit.HTTP1.Handler`
  # process, and it moves an HTTP/1 request through its lifecycle by calling functions defined on
  # this module. This state is also tracked within the `Bandit.Adapter` instance that backs
  # Bandit's Plug API.

  defstruct socket: nil,
            buffer: <<>>,
            read_state: :unread,
            write_state: :unsent,
            unread_content_length: nil,
            body_encoding: nil,
            version: :"HTTP/1.0",
            send_buffer: nil,
            request_connection_header: nil,
            keepalive: nil,
            opts: %{}

  @typedoc "An HTTP/1 read state"
  @type read_state :: :unread | :headers_read | :read

  @typedoc "An HTTP/1 write state"
  @type write_state :: :unsent | :writing | :chunking | :chunk_streaming | :sent

  @typedoc "The information necessary to communicate to/from a socket"
  @type t :: %__MODULE__{
          socket: ThousandIsland.Socket.t(),
          buffer: iodata(),
          read_state: read_state(),
          write_state: write_state(),
          unread_content_length: non_neg_integer() | :chunked | nil,
          body_encoding: nil | binary(),
          version: nil | :"HTTP/1.1" | :"HTTP/1.0",
          send_buffer: iolist(),
          request_connection_header: binary(),
          keepalive: boolean(),
          opts: %{
            required(:http_1) => Bandit.http_1_options()
          }
        }

  defimpl Bandit.HTTPTransport do
    require Logger

    @max_chunk_size_byte_count 16

    def peer_data(%@for{} = socket), do: Bandit.SocketHelpers.peer_data(socket.socket)

    def sock_data(%@for{} = socket), do: Bandit.SocketHelpers.sock_data(socket.socket)

    def ssl_data(%@for{} = socket), do: Bandit.SocketHelpers.ssl_data(socket.socket)

    def version(%@for{} = socket), do: socket.version

    def read_headers(%@for{read_state: :unread} = socket) do
      {method, request_target, socket} = do_read_request_line!(socket)
      {headers, socket} = do_read_headers!(socket)
      content_length = get_content_length!(headers)
      body_encoding = safe_downcase(Bandit.Headers.get_header(headers, "transfer-encoding"))
      request_connection_header = safe_downcase(Bandit.Headers.get_header(headers, "connection"))
      socket = %{socket | request_connection_header: request_connection_header}

      case {content_length, body_encoding} do
        {nil, nil} ->
          # No body, so just go straight to 'read'
          {:ok, method, request_target, headers, %{socket | read_state: :read}}

        {content_length, nil} ->
          socket = %{socket | read_state: :headers_read, unread_content_length: content_length}
          {:ok, method, request_target, headers, socket}

        {nil, body_encoding} ->
          socket = %{socket | read_state: :headers_read, body_encoding: body_encoding}
          {:ok, method, request_target, headers, socket}

        {_content_length, _body_encoding} ->
          request_error!(
            "Request cannot contain both 'content-length' and 'transfer-encoding' (RFC9112§6.3.3)"
          )
      end
    end

    defp do_read_request_line!(socket, request_target \\ nil) do
      packet_size = Keyword.get(socket.opts.http_1, :max_request_line_length, 10_000)

      case :erlang.decode_packet(:http_bin, socket.buffer, packet_size: packet_size) do
        {:more, _len} ->
          chunk = read_available!(socket.socket, socket.socket.read_timeout)
          do_read_request_line!(%{socket | buffer: socket.buffer <> chunk}, request_target)

        {:ok, {:http_request, method, request_target, version}, rest} ->
          version = get_version!(version)
          # decode_packet is inconsistent about atom/string method returns
          method = to_string(method)
          request_target = resolve_request_target!(request_target, method)
          socket = %{socket | buffer: rest, version: version}
          {method, request_target, socket}

        {:ok, {:http_error, reason}, _rest} ->
          request_error!("Request line HTTP error: #{inspect(reason)}")

        {:error, :invalid} ->
          request_error!("Request URI is too long", :request_uri_too_long)

        {:error, reason} ->
          request_error!("Request line unknown error: #{inspect(reason)}")
      end
    end

    defp get_version!({1, 1}), do: :"HTTP/1.1"
    defp get_version!({1, 0}), do: :"HTTP/1.0"
    defp get_version!(other), do: request_error!("Invalid HTTP version: #{inspect(other)}")

    # Unwrap different request_targets returned by :erlang.decode_packet/3
    defp resolve_request_target!({:abs_path, path}, _), do: {nil, nil, nil, path}

    defp resolve_request_target!({:absoluteURI, scheme, host, :undefined, path}, _),
      do: {to_string(scheme), host, nil, path}

    defp resolve_request_target!({:absoluteURI, scheme, host, port, path}, _),
      do: {to_string(scheme), host, port, path}

    defp resolve_request_target!(:*, "OPTIONS"), do: {nil, nil, nil, :*}

    defp resolve_request_target!({:scheme, scheme, port}, "CONNECT"),
      do: {nil, scheme, port, nil}

    defp resolve_request_target!(_request_target, _method),
      do: request_error!("Unsupported request target (RFC9112§3.2)")

    defp do_read_headers!(%@for{} = socket, headers \\ []) do
      packet_size = Keyword.get(socket.opts.http_1, :max_header_length, 10_000)

      case :erlang.decode_packet(:httph_bin, socket.buffer, packet_size: packet_size) do
        {:more, _len} ->
          chunk = read_available!(socket.socket, socket.socket.read_timeout)
          socket = %{socket | buffer: socket.buffer <> chunk}
          do_read_headers!(socket, headers)

        {:ok, {:http_header, _, header, _, value}, rest} ->
          socket = %{socket | buffer: rest}
          headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]

          if length(headers) <= Keyword.get(socket.opts.http_1, :max_header_count, 50) do
            do_read_headers!(socket, headers)
          else
            request_error!("Too many headers", :request_header_fields_too_large)
          end

        {:ok, :http_eoh, rest} ->
          socket = %{socket | read_state: :headers_read, buffer: rest}
          {Enum.reverse(headers), socket}

        {:ok, {:http_error, reason}, _rest} ->
          request_error!("Header read HTTP error: #{inspect(reason)}")

        {:error, :invalid} ->
          request_error!("Header too long", :request_header_fields_too_large)

        {:error, reason} ->
          request_error!("Header read unknown error: #{inspect(reason)}")
      end
    end

    defp get_content_length!(headers) do
      case Bandit.Headers.get_content_length(headers) do
        {:ok, content_length} -> content_length
        {:error, reason} -> request_error!("Content length unknown error: #{inspect(reason)}")
      end
    end

    def read_data(
          %@for{read_state: :headers_read, unread_content_length: unread_content_length} = socket,
          opts
        )
        when is_number(unread_content_length) do
      {body, buffer} =
        do_read_content_length_data!(socket.socket, socket.buffer, unread_content_length, opts)

      remaining_unread_content_length = unread_content_length - IO.iodata_length(body)

      socket = %{socket | buffer: buffer, unread_content_length: remaining_unread_content_length}

      if remaining_unread_content_length == 0 do
        {:ok, body, %{socket | read_state: :read}}
      else
        {:more, body, socket}
      end
    end

    def read_data(%@for{read_state: :headers_read, body_encoding: "chunked"} = socket, opts) do
      case do_read_chunked_data!(socket.socket, socket.buffer, <<>>, opts) do
        {:ok, body, buffer} ->
          {:ok, IO.iodata_to_binary(body), %{socket | read_state: :read, buffer: buffer}}

        {:more, body, buffer} ->
          {:more, IO.iodata_to_binary(body), %{socket | buffer: buffer}}
      end
    end

    def read_data(%@for{read_state: :headers_read, body_encoding: body_encoding}, _opts)
        when not is_nil(body_encoding) do
      request_error!("Unsupported transfer-encoding")
    end

    def read_data(%@for{} = socket, _opts), do: {:ok, <<>>, socket}

    defp do_read_content_length_data!(socket, buffer, unread_content_length, opts) do
      bytes_to_return = min(unread_content_length, Keyword.get(opts, :length, 8_000_000))
      read_size = Keyword.get(opts, :read_length, 1_000_000)
      read_timeout = Keyword.get(opts, :read_timeout, 15_000)
      read_exactly!(socket, buffer, bytes_to_return, read_size, read_timeout)
    end

    # do_read_chunked_data! reads up to the configured length, reading multiple
    # chunks to do so. It accumulates data in the 'body' list, adding to it
    # chunk by (possibly partial) chunk until either the end of the body is reached
    # or the configured length is exceeded
    @dialyzer {:no_improper_lists, do_read_chunked_data!: 4}
    defp do_read_chunked_data!(socket, buffer, body, opts) do
      max_to_read = Keyword.get(opts, :length, 8_000_000) - IO.iodata_length(body)

      case do_read_chunk!(socket, buffer, max_to_read, opts) do
        {<<>>, rest} ->
          {:ok, body, rest}

        {chunk, rest} ->
          if IO.iodata_length(chunk) < max_to_read do
            do_read_chunked_data!(socket, rest, [body | chunk], opts)
          else
            {:more, [body | chunk], rest}
          end
      end
    end

    # do_read_chunk will read a single chunk, including the header length and
    # trailing \r\n marker. In the case of chunks which are longer than max_to_read,
    # it will read max_to_read bytes and then push a fake chunk header onto the
    # buffer which subsequent calls will see as a regular chunk header.
    @dialyzer {:no_improper_lists, do_read_chunk!: 4}
    defp do_read_chunk!(socket, buffer, max_to_read, opts) do
      # This is only called at the *start* of a chunk.  As such, the only well formed data here is
      # the start of a chunk (ie: a hex number followed by \r\n followed by data).
      # do_read_chunk_size! will raise an error if it is unable to find a valid chunk start within
      # the first @max_chunk_size_byte_count bytes

      case do_read_chunk_size!(socket, buffer, opts) do
        {0, rest} ->
          {trailers, fake_socket} =
            do_read_headers!(%@for{socket: socket, buffer: rest, opts: %{http_1: []}})

          if trailers != [],
            do: Logger.warning("Encountered trailers in chunked request; ignoring")

          {<<>>, fake_socket.buffer}

        {chunk_size, rest} ->
          to_read = min(chunk_size, max_to_read)
          read_size = Keyword.get(opts, :read_length, 1_000_000)
          read_timeout = Keyword.get(opts, :read_timeout, 15_000)

          {to_return, rest} = read_exactly!(socket, rest, to_read, read_size, read_timeout)

          case chunk_size - to_read do
            0 ->
              {newline, rest} = read_exactly!(socket, rest, 2, read_size, read_timeout)

              if IO.iodata_to_binary(newline) != "\r\n",
                do: request_error!("Malformed chunked encoding request body")

              {to_return, rest}

            remaining when remaining > 0 ->
              # Build a binary since we'll be passing it to read_chunk_size! which expects a binary
              {to_return, Integer.to_string(remaining, 16) <> "\r\n" <> rest}
          end
      end
    end

    # Reads the chunk header, taking care to only read up to @max_chunk_size_byte_count bytes to do so. Protects
    # against arbitrarily long chunk headers per RFC9112§7.1
    defp do_read_chunk_size!(socket, buffer, opts)
         when byte_size(buffer) < @max_chunk_size_byte_count do
      case :binary.match(buffer, "\r\n") do
        {chunk_size_size, 2} ->
          do_parse_chunk_size(buffer, chunk_size_size)

        :nomatch ->
          # We don't yet have a valid chunk prefix. Keep reading until we do
          # Intentionally build a binary and not an iolist so we safely call ourselves again
          more = read_available!(socket, Keyword.get(opts, :read_timeout, 15_000))
          do_read_chunk_size!(socket, buffer <> more, opts)
      end
    end

    defp do_read_chunk_size!(_socket, buffer, _opts) do
      case :binary.match(buffer, "\r\n", [{:scope, {0, @max_chunk_size_byte_count}}]) do
        {chunk_size_size, 2} ->
          do_parse_chunk_size(buffer, chunk_size_size)

        :nomatch ->
          request_error!(
            "Was not able to parse a chunk size less than #{@max_chunk_size_byte_count} octets in length"
          )
      end
    end

    defp do_parse_chunk_size(buffer, chunk_size_size) do
      <<chunk_size::binary-size(^chunk_size_size), "\r\n", rest::binary>> = buffer
      chunk_size = String.to_integer(chunk_size, 16)
      {chunk_size, rest}
    end

    ##################
    # Internal Reading
    ##################

    @compile {:inline, read_available!: 2}
    @spec read_available!(ThousandIsland.Socket.t(), timeout()) :: binary()
    defp read_available!(socket, read_timeout) do
      case ThousandIsland.Socket.recv(socket, 0, read_timeout) do
        {:ok, chunk} when byte_size(chunk) > 0 -> chunk
        # The empty body case is possible in some specific edge cases and we don't want to recurse
        {:ok, <<>>} -> handle_timeout_with_disconnect_check!(socket)
        {:error, :timeout} -> handle_timeout_with_disconnect_check!(socket)
        {:error, reason} -> socket_error!(reason)
      end
    end

    @dialyzer {:no_improper_lists, read_exactly!: 5}
    @compile {:inline, read_exactly!: 5}
    defp read_exactly!(socket, buffer, to_read, read_size, read_timeout) when to_read >= 0 do
      case to_read - IO.iodata_length(buffer) do
        bytes_still_to_read when bytes_still_to_read == 0 ->
          # buffer is exactly the right size. Return it directly to save a binary conversion

          {buffer, <<>>}

        bytes_still_to_read when bytes_still_to_read < 0 ->
          # We somehow have too much (likely because we were handed an oversized buffer to start)
          # We need to binary-ize it in order to split it in size
          <<to_return::binary-size(^to_read), rest::binary>> = IO.iodata_to_binary(buffer)

          {to_return, rest}

        bytes_still_to_read when bytes_still_to_read > 0 ->
          # We need to read from the wire to hit our required length. Limit ourselves to the
          # prescribed read_size
          actual_read_size = min(bytes_still_to_read, read_size)

          case ThousandIsland.Socket.recv(socket, actual_read_size, read_timeout) do
            {:ok, data} when byte_size(data) > 0 ->
              read_exactly!(socket, [buffer | data], to_read, read_size, read_timeout)

            {:error, :timeout} ->
              handle_timeout_with_disconnect_check!(socket)

            {:error, reason} ->
              socket_error!(reason)
          end
      end
    end

    # After a timeout, check if the peer is still connected. If not, this is
    # likely a client disconnect that manifested as a timeout.
    # We raise TransportError for disconnects and HTTPError for genuine timeouts.
    # Use a non-blocking recv (timeout: 0) to detect closed connections.
    @spec handle_timeout_with_disconnect_check!(ThousandIsland.Socket.t()) :: no_return()
    defp handle_timeout_with_disconnect_check!(socket) do
      case ThousandIsland.Socket.recv(socket, 0, 0) do
        {:error, :timeout} ->
          # Socket is still open but no data - genuine timeout
          request_error!("Read timeout", :request_timeout)

        {:error, reason} ->
          # Socket error (e.g., :closed) - client disconnected
          socket_error!(reason)

        {:ok, _data} ->
          # Unexpected: data arrived just after timeout. Treat as timeout
          # since we already committed to the timeout path.
          request_error!("Body read timeout", :request_timeout)
      end
    end

    def send_headers(%@for{write_state: :unsent} = socket, status, headers, body_disposition) do
      resp_line = "#{socket.version} #{status} #{Plug.Conn.Status.reason_phrase(status)}\r\n"

      {headers, socket} = handle_keepalive(status, headers, socket)

      has_content_length = Bandit.Headers.get_header(headers, "content-length") != nil

      case body_disposition do
        :raw ->
          # This is an optimization for the common case of sending a non-encoded body (or file),
          # and coalesces the header and body send calls into a single ThousandIsland.Socket.send/2
          # call. This makes a _substantial_ difference in practice
          %{socket | write_state: :writing, send_buffer: [resp_line | encode_headers(headers)]}

        :chunk_encoded when not has_content_length ->
          headers = [{"transfer-encoding", "chunked"} | headers]
          send!(socket.socket, [resp_line | encode_headers(headers)])
          %{socket | write_state: :chunking}

        :chunk_encoded when has_content_length ->
          send!(socket.socket, [resp_line | encode_headers(headers)])
          %{socket | write_state: :chunk_streaming}

        :no_body ->
          send!(socket.socket, [resp_line | encode_headers(headers)])
          %{socket | write_state: :sent}

        :inform ->
          send!(socket.socket, [resp_line | encode_headers(headers)])
          %{socket | write_state: :unsent}
      end
    end

    defp handle_keepalive(status, headers, socket) do
      response_connection_header = safe_downcase(Bandit.Headers.get_header(headers, "connection"))

      # Per RFC9112§9.3
      cond do
        status in 100..199 ->
          {headers, socket}

        socket.request_connection_header == "close" || response_connection_header == "close" ->
          {headers, %{socket | keepalive: false}}

        socket.version == :"HTTP/1.1" ->
          {headers, %{socket | keepalive: true}}

        socket.version == :"HTTP/1.0" && socket.request_connection_header == "keep-alive" ->
          {[{"connection", "keep-alive"} | headers], %{socket | keepalive: true}}

        true ->
          {[{"connection", "close"} | headers], %{socket | keepalive: false}}
      end
    end

    defp safe_downcase(str) when is_binary(str), do: String.downcase(str, :ascii)
    defp safe_downcase(str), do: str

    defp encode_headers(headers) do
      headers
      |> Enum.map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
      |> then(&[&1 | ["\r\n"]])
    end

    def send_data(%@for{write_state: :writing} = socket, data, end_request) do
      send!(socket.socket, [socket.send_buffer | data])
      write_state = if end_request, do: :sent, else: :writing
      %{socket | write_state: write_state, send_buffer: []}
    end

    def send_data(%@for{write_state: :chunking} = socket, data, end_request) do
      byte_size = data |> IO.iodata_length()
      send!(socket.socket, [Integer.to_string(byte_size, 16), "\r\n", data, "\r\n"])
      write_state = if end_request, do: :sent, else: :chunking
      %{socket | write_state: write_state}
    end

    def send_data(%@for{write_state: :chunk_streaming} = socket, data, end_request) do
      send!(socket.socket, data)
      write_state = if end_request, do: :sent, else: :chunk_streaming
      %{socket | write_state: write_state}
    end

    def sendfile(%@for{write_state: :writing} = socket, path, offset, length) do
      send!(socket.socket, socket.send_buffer)

      case ThousandIsland.Socket.sendfile(socket.socket, path, offset, length) do
        {:ok, _bytes_written} -> %{socket | write_state: :sent}
        {:error, reason} -> socket_error!(reason)
      end
    end

    @spec send!(ThousandIsland.Socket.t(), iolist()) :: :ok | no_return()
    defp send!(socket, payload) do
      case ThousandIsland.Socket.send(socket, payload) do
        :ok ->
          :ok

        {:error, reason} ->
          # Prevent error handlers from possibly trying to send again
          send(self(), {:plug_conn, :sent})
          socket_error!(reason)
      end
    end

    def ensure_completed(%@for{read_state: :read} = socket), do: socket
    def ensure_completed(%@for{keepalive: false} = socket), do: socket

    def ensure_completed(%@for{} = socket) do
      case read_data(socket, []) do
        {:ok, _data, socket} -> socket
        {:more, _data, _socket} -> request_error!("Unable to read remaining data in request body")
      end
    rescue
      e in [Bandit.HTTPError] ->
        # If we got a timeout during ensure_completed (draining the body),
        # check if the client actually disconnected.
        if e.plug_status == :request_timeout do
          handle_timeout_with_disconnect_check!(socket.socket)
        else
          reraise e, __STACKTRACE__
        end
    end

    def supported_upgrade?(%@for{} = _socket, protocol), do: protocol == :websocket

    def send_on_error(%@for{}, %Bandit.TransportError{}), do: :ok

    def send_on_error(%@for{} = socket, error) do
      receive do
        {:plug_conn, :sent} -> %{socket | write_state: :sent}
      after
        0 ->
          status = error |> Plug.Exception.status() |> Plug.Conn.Status.code()

          try do
            send_headers(socket, status, [{"connection", "close"}], :no_body)
          rescue
            _e in [Bandit.TransportError, Bandit.HTTPError] -> :ok
          end
      end
    end

    @spec request_error!(term()) :: no_return()
    @spec request_error!(term(), Plug.Conn.status()) :: no_return()
    defp request_error!(reason, plug_status \\ :bad_request) do
      raise Bandit.HTTPError, message: to_string(reason), plug_status: plug_status
    end

    @spec socket_error!(term()) :: no_return()
    defp socket_error!(reason) do
      raise Bandit.TransportError, message: "Unrecoverable error: #{reason}", error: reason
    end
  end
end
