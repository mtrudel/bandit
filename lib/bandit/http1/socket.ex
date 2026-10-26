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
            close_after_response: false,
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
          close_after_response: boolean(),
          keepalive: boolean(),
          opts: %{
            required(:http_1) => Bandit.http_1_options()
          }
        }

  defimpl Bandit.HTTPTransport do
    require Logger

    @max_chunk_size_byte_count 16

    # RFC9110§5.6.2: tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
    # "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    defguardp is_tchar(char)
              when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
                     char in ~c"!#$%&'*+-.^_`|~"

    def peer_data(%@for{} = socket), do: Bandit.SocketHelpers.peer_data(socket.socket)

    def sock_data(%@for{} = socket), do: Bandit.SocketHelpers.sock_data(socket.socket)

    def ssl_data(%@for{} = socket), do: Bandit.SocketHelpers.ssl_data(socket.socket)

    def version(%@for{} = socket), do: socket.version

    def read_headers(%@for{read_state: :unread} = socket) do
      {method, request_target, socket} = do_read_request_line!(socket)
      {headers, socket} = do_read_headers!(socket)
      content_length = get_content_length!(headers)
      body_encoding = headers |> get_transfer_encoding!() |> validate_transfer_encoding!()
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
          # Per RFC9112§6.1, a server that receives an HTTP/1.0 message with a
          # Transfer-Encoding header field MUST treat the message as if the framing is
          # faulty and close the connection after processing the message.
          if socket.version == :"HTTP/1.0" do
            request_error!("Transfer-encoding is not valid for HTTP/1.0 requests (RFC9112§6.1)")
          end

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
          request_line = binary_part(socket.buffer, 0, byte_size(socket.buffer) - byte_size(rest))
          version = get_version!(version, request_line)
          # decode_packet is inconsistent about atom/string method returns
          method = to_string(method)
          request_target = resolve_request_target!(request_target, method, request_line)
          validate_request_line!(method, request_target)
          socket = %{socket | buffer: rest, version: version}
          {method, request_target, socket}

        {:ok, {:http_error, "\r\n"}, rest} ->
          # RFC9112§2.2: servers SHOULD ignore at least one empty line (CRLF) received
          # prior to the request line
          do_read_request_line!(%{socket | buffer: rest}, request_target)

        {:ok, {:http_error, reason}, _rest} ->
          request_error!("Request line HTTP error: #{inspect(reason)}")

        {:error, :invalid} ->
          request_error!("Request URI is too long", :request_uri_too_long)

        {:error, reason} ->
          request_error!("Request line unknown error: #{inspect(reason)}")
      end
    end

    # RFC9112§3.2 - the request-target may not contain CTLs or whitespace. We check the method
    # and every component of the request-target, since all of them reach the Plug.Conn
    defp validate_request_line!(method, {scheme, host, port, path}) do
      [method, scheme, host, port, path]
      |> Enum.all?(&request_line_component_valid?/1)
      |> if do
        :ok
      else
        request_error!("Request line contains invalid characters (RFC9112§3.2)")
      end
    end

    defp request_line_component_valid?(<<>>), do: true

    defp request_line_component_valid?(<<char, rest::binary>>) when char > 0x20 and char != 0x7F,
      do: request_line_component_valid?(rest)

    defp request_line_component_valid?(<<_char, _rest::binary>>), do: false

    # Request line components which are not binaries (ports, the :* path) cannot contain bytes
    defp request_line_component_valid?(_component), do: true

    # decode_packet reads the version numbers into C integers, which wrap (so 'HTTP/4294967297.1'
    # reads as HTTP/1.1), and it accepts more than the RFC9112§2.3 grammar allows ('HTTP/01.01',
    # 'HTTP/1.1.1', 'HTTP/1.1x'). It also ignores any words after the version. A front end that
    # reads such a request line differently can disagree with us about the target, or about how
    # the message is framed. Thus require the line to be exactly three words, the last of which
    # is the version text
    defp get_version!(version, request_line) when version in [{1, 1}, {1, 0}] do
      case {version, request_line_words(request_line)} do
        {{1, 1}, [_method, _target, "HTTP/1.1"]} ->
          :"HTTP/1.1"

        {{1, 0}, [_method, _target, "HTTP/1.0"]} ->
          :"HTTP/1.0"

        {_, [_method, _target, raw]} ->
          request_error!("Invalid HTTP version: #{inspect(raw)} (RFC9112§2.3)")

        _ ->
          request_error!("Request line does not have exactly three words (RFC9112§3)")
      end
    end

    defp get_version!(other, _request_line),
      do: request_error!("Invalid HTTP version: #{inspect(other)}")

    # The words of a request line, without its CRLF or (per RFC9112§2.2) bare LF line ending
    defp request_line_words(request_line) do
      request_line
      |> String.replace_suffix("\n", "")
      |> String.replace_suffix("\r", "")
      |> :binary.split([" ", "\t"], [:global, :trim_all])
    end

    # Unwrap different request_targets returned by :erlang.decode_packet/3
    defp resolve_request_target!({:abs_path, path}, _, _), do: {nil, nil, nil, path}

    # decode_packet parses an absolute-form target loosely. It reads the port into a C integer,
    # which wraps (so 'host:4294967376' reads as port 80), and it silently drops a port that it
    # cannot parse (so 'host:-1' reads as no port). It also ends the authority only at ':' or
    # '/', so in 'http://host:80?q=/admin' it takes '/admin' as the path, where RFC3986§3 takes
    # an empty path and the query 'q=/admin'. Split the target from the request line as
    # RFC3986§3 does. The pipeline then holds the host and port to the same grammar as a Host
    # header. If the two parsers disagree about the path, other parsers can disagree too, so
    # reject the request
    defp resolve_request_target!({:absoluteURI, scheme, _host, _port, path}, _, request_line) do
      case parse_absolute_form(request_line) do
        {host, port, ^path} -> {to_string(scheme), host, port, path}
        _ -> request_error!("Request target has an ambiguous path (RFC9112§3.2.2)")
      end
    end

    defp resolve_request_target!(:*, "OPTIONS", _), do: {nil, nil, nil, :*}

    defp resolve_request_target!({:scheme, scheme, port}, "CONNECT", _),
      do: {nil, scheme, port, nil}

    defp resolve_request_target!(_request_target, _method, _),
      do: request_error!("Unsupported request target (RFC9112§3.2)")

    # The authority of an absolute-form target starts after the first '://' in the request line
    # (a method cannot contain ':' or '/'), and ends at the start of the path, query or fragment.
    # The target ends at the whitespace before the version. Control bytes are left in place, for
    # validate_request_line!/2 to reject
    defp parse_absolute_form(request_line) do
      [_method_and_scheme, rest] = :binary.split(request_line, "://")
      [target | _] = :binary.split(rest, [" ", "\t"])
      [authority | _] = :binary.split(target, ["/", "?", "#"])

      path_and_query =
        binary_part(target, byte_size(authority), byte_size(target) - byte_size(authority))

      {host, port} = split_authority(authority)
      {host, port, absolute_form_path(path_and_query)}
    end

    # RFC9110§4.2.1: an empty path is the same as '/'
    defp absolute_form_path(""), do: "/"
    defp absolute_form_path("/" <> _ = path), do: path
    defp absolute_form_path(query_or_fragment), do: "/" <> query_or_fragment

    # Leaves malformed authorities intact for the pipeline to reject (RFC3986§3.2)
    defp split_authority("[" <> _ = authority) do
      case :binary.split(authority, "]") do
        [literal, ""] -> {literal <> "]", nil}
        [literal, ":" <> port] -> {literal <> "]", port}
        [_literal, _suffix] -> {authority, nil}
        [_unterminated] -> {authority, nil}
      end
    end

    defp split_authority(authority) do
      case :binary.split(authority, ":") do
        [host, port] -> {host, port}
        [host] -> {host, nil}
      end
    end

    # RFC9112§2.2 lets a recipient take a bare LF as the end of a line, and :erlang.decode_packet/3
    # does so. That is kept for the header section. Within a chunked body (the trailer section)
    # every line must end in CRLF instead, as the chunk-size and chunk-data lines must: a proxy
    # that ends trailer lines only at CRLF reads a different end of body than one that also ends
    # them at a bare LF, which lets a client smuggle a request (see GHSA-w5wc-g2hc-g7m2)
    defp do_read_headers!(%@for{} = socket, line_ending \\ :lf) do
      packet_size = Keyword.get(socket.opts.http_1, :max_header_length, 10_000)
      max_header_count = Keyword.get(socket.opts.http_1, :max_header_count, 50)
      do_read_headers!(socket, line_ending, packet_size, max_header_count, [], 0)
    end

    defp do_read_headers!(
           socket,
           line_ending,
           packet_size,
           max_header_count,
           headers,
           header_count
         ) do
      case :erlang.decode_packet(:httph_bin, socket.buffer, packet_size: packet_size) do
        {:more, _len} ->
          chunk = read_available!(socket.socket, socket.socket.read_timeout)
          socket = %{socket | buffer: socket.buffer <> chunk}

          do_read_headers!(
            socket,
            line_ending,
            packet_size,
            max_header_count,
            headers,
            header_count
          )

        {:ok, {:http_header, _, header, _, value}, rest} ->
          validate_line_ending!(line_ending, socket.buffer, rest)
          validate_field_value!(value)
          socket = %{socket | buffer: rest}
          headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]
          header_count = header_count + 1

          if header_count <= max_header_count do
            do_read_headers!(
              socket,
              line_ending,
              packet_size,
              max_header_count,
              headers,
              header_count
            )
          else
            request_error!("Too many headers", :request_header_fields_too_large)
          end

        {:ok, :http_eoh, rest} ->
          validate_line_ending!(line_ending, socket.buffer, rest)
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

    # decode_packet consumed the line from buffer, leaving rest
    defp validate_line_ending!(:lf, _buffer, _rest), do: :ok

    defp validate_line_ending!(:crlf, buffer, rest) do
      line_length = byte_size(buffer) - byte_size(rest)

      if line_length >= 2 and binary_part(buffer, line_length - 2, 2) == "\r\n" do
        :ok
      else
        request_error!("Trailer section line does not end in CRLF (RFC9112§7.1.2)")
      end
    end

    @spec validate_field_value!(binary()) :: :ok
    defp validate_field_value!(value) do
      if Bandit.Headers.field_value_valid?(value) do
        :ok
      else
        request_error!("Field value contains invalid characters (RFC9110§5.5)")
      end
    end

    defp get_content_length!(headers) do
      case Bandit.Headers.get_content_length(headers) do
        {:ok, content_length} -> content_length
        {:error, reason} -> request_error!("Content length unknown error: #{inspect(reason)}")
      end
    end

    defp get_transfer_encoding!(headers) do
      case Bandit.Headers.get_transfer_encoding(headers) do
        {:ok, transfer_encoding} -> safe_downcase(transfer_encoding)
        {:error, reason} -> request_error!("Transfer encoding unknown error: #{inspect(reason)}")
      end
    end

    # RFC9112§6.3 requires a 400 response when a request's final transfer coding
    # is not chunked. Reject it while reading the headers so the request cannot be
    # dispatched to Plug before its framing has been validated.
    defp validate_transfer_encoding!(nil), do: nil

    defp validate_transfer_encoding!(encoding) do
      codings = Plug.Conn.Utils.list(encoding)

      cond do
        codings == ["chunked"] ->
          "chunked"

        Enum.count(codings, &(&1 == "chunked")) > 1 ->
          request_error!("Transfer-encoding cannot apply chunked more than once (RFC9112§6.1)")

        List.last(codings) != "chunked" ->
          request_error!(
            "Final transfer coding in a request must be chunked (RFC9112§6.3 rule 4)"
          )

        true ->
          request_error!("Unsupported transfer-encoding", :not_implemented)
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
      case do_read_chunked_data!(socket.socket, socket.buffer, <<>>, 0, opts) do
        {:ok, body, buffer} ->
          {:ok, body, %{socket | read_state: :read, buffer: buffer}}

        {:more, body, buffer} ->
          {:more, body, %{socket | buffer: buffer}}
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
    # chunks to do so. It accumulates data in the 'body' binary, appending to it
    # chunk by (possibly partial) chunk until either the end of the body is reached
    # or the configured length is exceeded. Note that an exhausted read budget must
    # be checked before attempting to read a chunk, since a zero-byte chunk read is
    # otherwise indistinguishable from the terminal chunk.
    #
    # The body is a binary and not an iolist because the configured length limits the bytes
    # in the body, not the number of chunks they arrive in. An iolist uses a list cell and a
    # binary term for each chunk, so a body sent as one-byte chunks uses many times its own
    # size in memory (GHSA-jwh3-j29h-qfmw). Appending to a binary uses memory in proportion to
    # the bytes only
    defp do_read_chunked_data!(socket, buffer, body, body_length, opts) do
      max_to_read = Keyword.get(opts, :length, 8_000_000) - body_length

      if max_to_read <= 0 do
        {:more, body, buffer}
      else
        do_read_next_chunk!(socket, buffer, body, body_length, max_to_read, opts)
      end
    end

    defp do_read_next_chunk!(socket, buffer, body, body_length, max_to_read, opts) do
      case do_read_chunk!(socket, buffer, max_to_read, opts) do
        {:done, rest} ->
          {:ok, body, rest}

        {:chunk, chunk, rest} ->
          length = IO.iodata_length(chunk)
          # A chunk at least as large as the body so far is joined to it with one copy of both,
          # which costs no more than appending, and avoids growing body several times over
          body =
            if length >= byte_size(body),
              do: IO.iodata_to_binary([body | chunk]),
              else: append_iodata(body, chunk)

          if length < max_to_read do
            do_read_chunked_data!(socket, rest, body, body_length + length, opts)
          else
            {:more, body, rest}
          end
      end
    end

    # Appends each binary in an (possibly improper) iolist to body, so that the data is copied
    # once. IO.iodata_to_binary/1 followed by an append would copy it twice
    @dialyzer {:no_improper_lists, append_iodata: 2}
    defp append_iodata(body, data) when is_binary(data), do: <<body::binary, data::binary>>
    defp append_iodata(body, []), do: body

    defp append_iodata(body, [head | tail]),
      do: body |> append_iodata(head) |> append_iodata(tail)

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
            do_read_headers!(%@for{socket: socket, buffer: rest, opts: %{http_1: []}}, :crlf)

          if trailers != [],
            do: Logger.warning("Encountered trailers in chunked request; ignoring")

          {:done, fake_socket.buffer}

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

              {:chunk, to_return, rest}

            remaining when remaining > 0 ->
              # Build a binary since we'll be passing it to read_chunk_size! which expects a binary
              {:chunk, to_return, Integer.to_string(remaining, 16) <> "\r\n" <> rest}
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
      <<chunk_size_line::binary-size(^chunk_size_size), "\r\n", rest::binary>> = buffer
      {chunk_size, chunk_ext} = split_chunk_size_line(chunk_size_line, 0)
      chunk_size = parse_chunk_size!(chunk_size)

      # Chunk extensions are ignored per RFC9112§7.1.1, but they must still match its grammar.
      # Without this check, a bare CR or LF in an extension is discarded as part of it. A
      # proxy which ends the size line at the bare LF then disagrees with us about where the
      # chunk data starts, and so where the body ends (GHSA-w5wc-g2hc-g7m2)
      if not valid_chunk_ext?(chunk_ext),
        do: request_error!("Invalid chunk extension (RFC9112§7.1.1)")

      {chunk_size, rest}
    end

    # Splits a chunk size line into its leading run of hex digits and everything after them
    defp split_chunk_size_line(line, count) do
      case line do
        <<_::binary-size(^count), digit, _::binary>>
        when digit in ?0..?9 or digit in ?a..?f or digit in ?A..?F ->
          split_chunk_size_line(line, count + 1)

        <<chunk_size::binary-size(^count), chunk_ext::binary>> ->
          {chunk_size, chunk_ext}
      end
    end

    # RFC9112§7.1 defines chunk-size as 1*HEXDIG
    @spec parse_chunk_size!(binary()) :: non_neg_integer()
    defp parse_chunk_size!(<<>>), do: request_error!("Unable to parse chunk size")
    defp parse_chunk_size!(chunk_size), do: String.to_integer(chunk_size, 16)

    # RFC9112§7.1.1:
    #
    #   chunk-ext      = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )
    #   chunk-ext-name = token
    #   chunk-ext-val  = token / quoted-string
    defp valid_chunk_ext?(<<>>), do: true

    defp valid_chunk_ext?(chunk_ext) do
      case skip_bws(chunk_ext) do
        ";" <> rest -> rest |> skip_bws() |> valid_chunk_ext_name?()
        _ -> false
      end
    end

    defp valid_chunk_ext_name?(<<char, _::binary>> = chunk_ext) when is_tchar(char) do
      rest = skip_token(chunk_ext)

      case skip_bws(rest) do
        "=" <> value -> value |> skip_bws() |> valid_chunk_ext_val?()
        _ -> valid_chunk_ext?(rest)
      end
    end

    defp valid_chunk_ext_name?(_chunk_ext), do: false

    defp valid_chunk_ext_val?(<<?", rest::binary>>), do: valid_quoted_string_rest?(rest)

    defp valid_chunk_ext_val?(<<char, _::binary>> = chunk_ext) when is_tchar(char),
      do: chunk_ext |> skip_token() |> valid_chunk_ext?()

    defp valid_chunk_ext_val?(_chunk_ext), do: false

    # RFC9110§5.6.4: quoted-string = DQUOTE *( qdtext / quoted-pair ) DQUOTE, where
    # qdtext = HTAB / SP / %x21 / %x23-5B / %x5D-7E / obs-text and
    # quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )
    defp valid_quoted_string_rest?(<<?", rest::binary>>), do: valid_chunk_ext?(rest)

    defp valid_quoted_string_rest?(<<?\\, char, rest::binary>>)
         when char == ?\t or char in 0x20..0x7E or char in 0x80..0xFF,
         do: valid_quoted_string_rest?(rest)

    defp valid_quoted_string_rest?(<<char, rest::binary>>)
         when char == ?\t or char in 0x20..0x21 or char in 0x23..0x5B or char in 0x5D..0x7E or
                char in 0x80..0xFF,
         do: valid_quoted_string_rest?(rest)

    defp valid_quoted_string_rest?(_chunk_ext), do: false

    defp skip_bws(<<char, rest::binary>>) when char in [?\s, ?\t], do: skip_bws(rest)
    defp skip_bws(rest), do: rest

    defp skip_token(<<char, rest::binary>>) when is_tchar(char), do: skip_token(rest)
    defp skip_token(rest), do: rest

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
      headers = remove_http_1_0_transfer_encoding(headers, socket)

      has_content_length = Bandit.Headers.get_header(headers, "content-length") != nil

      case body_disposition do
        :raw ->
          # This is an optimization for the common case of sending a non-encoded body (or file),
          # and coalesces the header and body send calls into a single ThousandIsland.Socket.send/2
          # call. This makes a _substantial_ difference in practice
          %{socket | write_state: :writing, send_buffer: [resp_line | encode_headers(headers)]}

        :chunk_encoded when not has_content_length and socket.version == :"HTTP/1.0" ->
          # HTTP/1.0 has no chunked transfer coding. Delimit the response body by closing the
          # connection, even if the client requested a persistent connection.
          headers =
            [{"connection", "close"} | Enum.reject(headers, &(elem(&1, 0) == "connection"))]

          send!(socket.socket, [resp_line | encode_headers(headers)])
          %{socket | write_state: :chunk_streaming, keepalive: false}

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

    # RFC9112§6.1 prohibits Transfer-Encoding in every response to an HTTP/1.0 request,
    # including a field supplied explicitly by the application.
    defp remove_http_1_0_transfer_encoding(headers, %@for{version: :"HTTP/1.0"}) do
      Enum.reject(headers, &(elem(&1, 0) == "transfer-encoding"))
    end

    defp remove_http_1_0_transfer_encoding(headers, _socket), do: headers

    defp handle_keepalive(status, headers, socket) do
      response_connection_header = safe_downcase(Bandit.Headers.get_header(headers, "connection"))

      # Per RFC9112§9.3
      cond do
        status in 100..199 ->
          {headers, socket}

        socket.close_after_response ->
          headers =
            [{"connection", "close"} | Enum.reject(headers, &(elem(&1, 0) == "connection"))]

          {headers, %{socket | keepalive: false}}

        Bandit.Headers.token_list_member?(socket.request_connection_header, "close") ||
            Bandit.Headers.token_list_member?(response_connection_header, "close") ->
          # Per RFC9112§9.6, a party that intends to close the connection SHOULD send a
          # 'close' connection option in its final message. If the response hasn't already
          # declared this itself, do so now (this happens when the client, not the plug,
          # is the one that asked for the connection to close).
          headers =
            if Bandit.Headers.token_list_member?(response_connection_header, "close") do
              headers
            else
              [{"connection", "close"} | Enum.reject(headers, &(elem(&1, 0) == "connection"))]
            end

          {headers, %{socket | keepalive: false}}

        socket.version == :"HTTP/1.1" ->
          {headers, %{socket | keepalive: true}}

        socket.version == :"HTTP/1.0" &&
            Bandit.Headers.token_list_member?(socket.request_connection_header, "keep-alive") ->
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

          # Empty error responses finish at the headers, without relying on a clean
          # EOF to delimit their body if the connection subsequently fails.
          headers = [{"connection", "close"}]
          headers = if status in 400..599, do: [{"content-length", "0"} | headers], else: headers

          try do
            send_headers(socket, status, headers, :no_body)
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
