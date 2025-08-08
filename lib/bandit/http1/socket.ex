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
    def peer_data(%@for{} = socket), do: Bandit.SocketHelpers.peer_data(socket.socket)

    def sock_data(%@for{} = socket), do: Bandit.SocketHelpers.sock_data(socket.socket)

    def ssl_data(%@for{} = socket), do: Bandit.SocketHelpers.ssl_data(socket.socket)

    def version(%@for{} = socket), do: socket.version

    def read_headers(%@for{read_state: :unread} = socket) do
      {method, request_target, socket} = do_read_request_line!(socket)
      {headers, socket} = do_read_headers!(socket)
      content_length = get_content_length!(headers)
      body_encoding = Bandit.Headers.get_header(headers, "transfer-encoding")
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
          chunk = read_available_for_header!(socket.socket)
          do_read_request_line!(%{socket | buffer: socket.buffer <> chunk}, request_target)

        {:ok, {:http_request, method, request_target, version}, rest} ->
          version = get_version!(version)
          request_target = resolve_request_target!(request_target)
          method = to_string(method)
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
    defp resolve_request_target!({:abs_path, path}), do: {nil, nil, nil, path}

    defp resolve_request_target!({:absoluteURI, scheme, host, :undefined, path}),
      do: {to_string(scheme), host, nil, path}

    defp resolve_request_target!({:absoluteURI, scheme, host, port, path}),
      do: {to_string(scheme), host, port, path}

    defp resolve_request_target!(:*), do: {nil, nil, nil, :*}

    defp resolve_request_target!({:scheme, _scheme, _path}),
      do: request_error!("schemeURI is not supported")

    defp resolve_request_target!(_request_target),
      do: request_error!("Unsupported request target (RFC9112§3.2)")

    defp do_read_headers!(socket, headers \\ []) do
      packet_size = Keyword.get(socket.opts.http_1, :max_header_length, 10_000)

      case :erlang.decode_packet(:httph_bin, socket.buffer, packet_size: packet_size) do
        {:more, _len} ->
          chunk = read_available_for_header!(socket.socket)
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
      {to_return, buffer, remaining_unread_content_length} =
        do_read_content_length_data!(socket.socket, socket.buffer, unread_content_length, opts)

      socket = %{socket | buffer: buffer, unread_content_length: remaining_unread_content_length}

      if remaining_unread_content_length == 0 do
        {:ok, to_return, %{socket | read_state: :read}}
      else
        {:more, to_return, socket}
      end
    end

    def read_data(%@for{read_state: :headers_read, body_encoding: "chunked"} = socket, opts) do
      read_size = Keyword.get(opts, :read_length, 1_000_000)
      read_timeout = Keyword.get(opts, :read_timeout)

      {body, buffer} =
        do_read_chunked_data!(socket.socket, socket.buffer, <<>>, read_size, read_timeout)

      body = IO.iodata_to_binary(body)

      {:ok, body, %{socket | read_state: :read, buffer: buffer}}
    end

    def read_data(%@for{read_state: :headers_read, body_encoding: body_encoding}, _opts)
        when not is_nil(body_encoding) do
      request_error!("Unsupported transfer-encoding")
    end

    def read_data(%@for{} = socket, _opts), do: {:ok, <<>>, socket}

    @dialyzer {:no_improper_lists, do_read_content_length_data!: 4}
    defp do_read_content_length_data!(socket, buffer, unread_content_length, opts) do
      max_to_return = min(unread_content_length, Keyword.get(opts, :length, 8_000_000))

      cond do
        max_to_return == 0 ->
          # We have already satisfied our content length
          {<<>>, buffer, unread_content_length}

        byte_size(buffer) >= max_to_return ->
          # We can satisfy the read request entirely from our buffer
          <<to_return::binary-size(max_to_return), rest::binary>> = buffer
          {to_return, rest, unread_content_length - max_to_return}

        byte_size(buffer) < max_to_return ->
          # We need to read off the wire
          read_size = Keyword.get(opts, :read_length, 1_000_000)
          read_timeout = Keyword.get(opts, :read_timeout)

          to_return =
            read!(socket, max_to_return - byte_size(buffer), [buffer], read_size, read_timeout)
            |> IO.iodata_to_binary()

          # We may have read more than we need to return
          if byte_size(to_return) >= max_to_return do
            <<to_return::binary-size(max_to_return), rest::binary>> = to_return
            {to_return, rest, unread_content_length - max_to_return}
          else
            {to_return, <<>>, unread_content_length - byte_size(to_return)}
          end
      end
    end

    @dialyzer {:no_improper_lists, do_read_chunked_data!: 5}
    defp do_read_chunked_data!(socket, buffer, body, read_size, read_timeout) do
      case :binary.split(buffer, "\r\n") do
        ["0", "\r\n" <> rest] ->
          # We should be reading (and ignoring) trailers here
          {IO.iodata_to_binary(body), rest}

        [chunk_size, rest] ->
          chunk_size = String.to_integer(chunk_size, 16)

          case rest do
            <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
              do_read_chunked_data!(socket, rest, [body, next_chunk], read_size, read_timeout)

            _ ->
              to_read = chunk_size - byte_size(rest)

              if to_read > 0 do
                iolist = read!(socket, to_read, [], read_size, read_timeout)
                buffer = IO.iodata_to_binary([buffer | iolist])
                do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
              else
                chunk = read_available!(socket, read_timeout)
                buffer = buffer <> chunk
                do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
              end
          end

        _ ->
          chunk = read_available!(socket, read_timeout)
          buffer = buffer <> chunk
          do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
      end
    end

    ##################
    # Internal Reading
    ##################

    @compile {:inline, read_available_for_header!: 1}
    @spec read_available_for_header!(ThousandIsland.Socket.t()) :: binary()
    defp read_available_for_header!(socket) do
      case ThousandIsland.Socket.recv(socket, 0) do
        {:ok, chunk} -> chunk
        {:error, reason} -> socket_error!(reason)
      end
    end

    @compile {:inline, read_available!: 2}
    @spec read_available!(ThousandIsland.Socket.t(), timeout()) :: binary()
    defp read_available!(socket, read_timeout) do
      case ThousandIsland.Socket.recv(socket, 0, read_timeout) do
        {:ok, chunk} -> chunk
        {:error, :timeout} -> <<>>
        {:error, reason} -> socket_error!(reason)
      end
    end

    @dialyzer {:no_improper_lists, read!: 5}
    @spec read!(
            ThousandIsland.Socket.t(),
            non_neg_integer(),
            iolist(),
            non_neg_integer(),
            timeout()
          ) ::
            iolist()
    defp read!(socket, to_read, already_read, read_size, read_timeout) do
      case ThousandIsland.Socket.recv(socket, min(to_read, read_size), read_timeout) do
        {:ok, chunk} ->
          remaining_bytes = to_read - byte_size(chunk)

          if remaining_bytes > 0 do
            read!(socket, remaining_bytes, [already_read | chunk], read_size, read_timeout)
          else
            [already_read | chunk]
          end

        {:error, :timeout} ->
          request_error!("Body read timeout", :request_timeout)

        {:error, reason} ->
          socket_error!(reason)
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

    def ensure_completed(%@for{} = socket) do
      case read_data(socket, []) do
        {:ok, _data, socket} -> socket
        {:more, _data, _socket} -> request_error!("Unable to read remaining data in request body")
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
