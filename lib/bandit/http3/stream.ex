defmodule Bandit.HTTP3.Stream do
  @moduledoc false
  # Represents an HTTP/3 request stream and implements `Bandit.HTTPTransport`.
  #
  # An instance of this struct is maintained as the state of a
  # `Bandit.HTTP3.StreamProcess` and is passed through the Plug pipeline.
  #
  # Naming conventions (mirroring HTTP/2 stream):
  #   - `deliver_*` functions: called by the Handler (connection process) to
  #     push incoming data into the stream process's mailbox via `send/2`.
  #   - HTTPTransport protocol functions: called by the Plug pipeline running
  #     inside the stream process; they block via `receive` when waiting for
  #     incoming data, and call GenServer.call on the connection process when
  #     sending outgoing data.
  #
  # No flow-control accounting is needed here; QUIC handles it transparently.

  require Logger

  defstruct connection_pid: nil,
            stream_id: nil,
            state: :idle,
            read_timeout: 15_000

  @typedoc "An HTTP/3 stream identifier (QUIC stream ID)"
  @type stream_id :: non_neg_integer()

  @typedoc "HTTP/3 stream state"
  @type state :: :idle | :open | :local_closed | :remote_closed | :closed

  @type t :: %__MODULE__{
          connection_pid: pid(),
          stream_id: non_neg_integer(),
          state: state(),
          read_timeout: timeout()
        }

  @spec init(pid(), stream_id(), keyword()) :: t()
  def init(connection_pid, stream_id, opts \\ []) do
    %__MODULE__{
      connection_pid: connection_pid,
      stream_id: stream_id,
      read_timeout: Keyword.get(opts, :read_timeout, 15_000)
    }
  end

  # ---------------------------------------------------------------------------
  # Delivery API — called by Handler to push received frames into stream process
  # ---------------------------------------------------------------------------

  @spec deliver_headers(pid(), Plug.Conn.headers(), boolean()) :: term()
  def deliver_headers(pid, headers, end_stream),
    do: send(pid, {:bandit_h3, :headers, headers, end_stream})

  @spec deliver_data(pid(), binary(), boolean()) :: term()
  def deliver_data(pid, data, end_stream),
    do: send(pid, {:bandit_h3, :data, data, end_stream})

  # ---------------------------------------------------------------------------
  # HTTPTransport protocol implementation
  # ---------------------------------------------------------------------------

  defimpl Bandit.HTTPTransport do
    def peer_data(%@for{} = stream), do: call(stream, {:peer_data, stream.stream_id})
    def sock_data(%@for{} = stream), do: call(stream, {:sock_data, stream.stream_id})
    def ssl_data(%@for{} = stream), do: call(stream, {:ssl_data, stream.stream_id})
    def version(%@for{}), do: :"HTTP/3"

    # -------------------------------------------------------------------------
    # read_headers — blocks until HEADERS frame arrives from Handler
    # -------------------------------------------------------------------------

    def read_headers(%@for{state: :idle} = stream) do
      receive do
        {:bandit_h3, :headers, headers, end_stream} ->
          method = Bandit.Headers.get_header(headers, ":method")
          request_target = build_request_target!(headers, stream)
          {pseudo_headers, regular_headers} = split_headers!(headers, stream)
          pseudo_headers_all_request!(pseudo_headers, stream)
          exactly_one_instance_of!(pseudo_headers, ":scheme", stream)
          exactly_one_instance_of!(pseudo_headers, ":method", stream)
          exactly_one_instance_of!(pseudo_headers, ":path", stream)
          headers_all_lowercase!(regular_headers, stream)
          no_connection_headers!(regular_headers, stream)
          valid_te_header!(regular_headers, stream)
          regular_headers = combine_cookie_crumbs(regular_headers)
          stream = %{stream | state: if(end_stream, do: :remote_closed, else: :open)}
          {:ok, method, request_target, regular_headers, stream}
      after
        stream.read_timeout ->
          stream_error!("Timed out waiting for HEADERS frame", stream)
      end
    end

    # -------------------------------------------------------------------------
    # read_data — buffers DATA frames until body is complete or max_bytes hit
    # -------------------------------------------------------------------------

    def read_data(%@for{state: :remote_closed} = stream, _opts) do
      {:ok, [], stream}
    end

    def read_data(%@for{state: state} = stream, opts)
        when state in [:open, :local_closed] do
      max_bytes = Keyword.get(opts, :length, 8_000_000)
      timeout = Keyword.get(opts, :read_timeout, 15_000)
      do_read_data(stream, max_bytes, timeout, [])
    end

    defp do_read_data(%@for{state: :remote_closed} = stream, _max, _timeout, acc) do
      {:ok, Enum.reverse(acc), stream}
    end

    defp do_read_data(%@for{state: state} = stream, max_bytes, timeout, acc)
         when state in [:open, :local_closed] do
      receive do
        {:bandit_h3, :data, data, end_stream} ->
          acc = [data | acc]
          remaining = max_bytes - byte_size(data)
          stream = if end_stream, do: transition_remote_closed(stream), else: stream

          if remaining >= 0 do
            do_read_data(stream, remaining, timeout, acc)
          else
            {:more, Enum.reverse(acc), stream}
          end
      after
        timeout -> {:more, Enum.reverse(acc), stream}
      end
    end

    # -------------------------------------------------------------------------
    # send_headers — encodes and sends response HEADERS via Handler
    # -------------------------------------------------------------------------

    def send_headers(%@for{state: state} = stream, status, headers, body_disposition)
        when state in [:open, :remote_closed] do
      end_stream = body_disposition == :no_body
      headers = [{":status", to_string(status)} | headers]
      call(stream, {:send_headers, stream.stream_id, headers, end_stream})
      transition_local_closed(stream, end_stream)
    end

    # -------------------------------------------------------------------------
    # send_data — sends a DATA frame via Handler
    # -------------------------------------------------------------------------

    def send_data(%@for{state: state} = stream, data, end_stream)
        when state in [:open, :remote_closed] do
      call(stream, {:send_data, stream.stream_id, IO.iodata_to_binary(data), end_stream})
      transition_local_closed(stream, end_stream)
    end

    # -------------------------------------------------------------------------
    # sendfile — reads file contents and sends as DATA (no OS sendfile over UDP)
    # -------------------------------------------------------------------------

    def sendfile(%@for{} = stream, path, offset, length) do
      case :file.open(path, [:raw, :binary]) do
        {:ok, fd} ->
          try do
            read_len = if length == :all, do: :infinity, else: length

            case :file.pread(fd, offset, read_len) do
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

    # -------------------------------------------------------------------------
    # ensure_completed — called after the Plug pipeline finishes
    # -------------------------------------------------------------------------

    def ensure_completed(%@for{state: :closed} = stream), do: stream

    def ensure_completed(%@for{state: :remote_closed} = stream), do: stream

    def ensure_completed(%@for{state: :local_closed} = stream) do
      # Drain any trailing DATA/HEADERS with FIN that may have arrived
      receive do
        {:bandit_h3, :data, _data, true} -> transition_remote_closed(stream)
        {:bandit_h3, :headers, _headers, true} -> transition_remote_closed(stream)
      after
        0 -> stream
      end
    end

    def ensure_completed(%@for{} = stream), do: stream

    # -------------------------------------------------------------------------
    # supported_upgrade? — HTTP/3 does not support WebSocket upgrades here
    # -------------------------------------------------------------------------

    def supported_upgrade?(%@for{}, _protocol), do: false

    # -------------------------------------------------------------------------
    # send_on_error — best-effort error response before termination
    # -------------------------------------------------------------------------

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

    # -------------------------------------------------------------------------
    # State transitions
    # -------------------------------------------------------------------------

    defp transition_local_closed(stream, false), do: stream

    defp transition_local_closed(%@for{state: :open} = stream, true),
      do: %{stream | state: :local_closed}

    defp transition_local_closed(%@for{state: :remote_closed} = stream, true),
      do: %{stream | state: :closed}

    defp transition_remote_closed(%@for{state: :open} = stream),
      do: %{stream | state: :remote_closed}

    defp transition_remote_closed(%@for{state: :local_closed} = stream),
      do: %{stream | state: :closed}

    defp transition_remote_closed(stream), do: stream

    # -------------------------------------------------------------------------
    # Header validation (RFC 9114 §4.3 — same rules as HTTP/2 per RFC 9113)
    # -------------------------------------------------------------------------

    defp build_request_target!(headers, stream) do
      scheme = Bandit.Headers.get_header(headers, ":scheme")
      {host, port} = get_host_and_port!(headers)
      path = get_path!(headers, stream)
      {scheme, host, port, path}
    end

    defp get_host_and_port!(headers) do
      case Bandit.Headers.get_header(headers, ":authority") do
        nil -> {nil, nil}
        authority -> Bandit.Headers.parse_hostlike_header!(authority)
      end
    end

    defp get_path!(headers, stream) do
      headers
      |> Bandit.Headers.get_header(":path")
      |> case do
        nil -> stream_error!("Received empty :path", stream)
        "*" -> :*
        "/" <> _ = path -> validate_path!(path, stream)
        _ -> stream_error!("Path does not start with /", stream)
      end
    end

    defp validate_path!(path, stream) do
      if path |> String.split("/") |> Enum.all?(&(&1 not in [".", ".."])),
        do: path,
        else: stream_error!("Path contains dot segment", stream)
    end

    defp split_headers!(headers, stream) do
      {pseudo, regular} =
        Enum.split_while(headers, fn {k, _} -> String.starts_with?(k, ":") end)

      if Enum.any?(regular, fn {k, _} -> String.starts_with?(k, ":") end),
        do: stream_error!("Pseudo-headers after regular headers", stream),
        else: {pseudo, regular}
    end

    defp pseudo_headers_all_request!(headers, stream) do
      valid = ~w[:method :scheme :authority :path]

      if Enum.any?(headers, fn {k, _} -> k not in valid end),
        do: stream_error!("Received invalid pseudo-header", stream)
    end

    defp exactly_one_instance_of!(headers, header, stream) do
      if Enum.count(headers, fn {k, _} -> k == header end) != 1,
        do: stream_error!("Expected exactly one #{header} header", stream)
    end

    defp headers_all_lowercase!(headers, stream) do
      if !Enum.all?(headers, fn {k, _} -> lowercase?(k) end),
        do: stream_error!("Received uppercase header name", stream)
    end

    defp lowercase?(<<c, _::bits>>) when c >= ?A and c <= ?Z, do: false
    defp lowercase?(<<_, rest::bits>>), do: lowercase?(rest)
    defp lowercase?(<<>>), do: true

    defp no_connection_headers!(headers, stream) do
      bad = ~w[connection keep-alive proxy-authenticate proxy-authorization
               trailers transfer-encoding upgrade]

      if Enum.any?(headers, fn {k, _} -> k in bad end),
        do: stream_error!("Received connection-specific header", stream)
    end

    defp valid_te_header!(headers, stream) do
      if Bandit.Headers.get_header(headers, "te") not in [nil, "trailers"],
        do: stream_error!("Received invalid TE header", stream)
    end

    defp combine_cookie_crumbs(headers) do
      {crumbs, rest} = Enum.split_with(headers, fn {k, _} -> k == "cookie" end)

      case Enum.map_join(crumbs, "; ", fn {"cookie", v} -> v end) do
        "" -> rest
        combined -> [{"cookie", combined} | rest]
      end
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    defp call(stream, msg), do: GenServer.call(stream.connection_pid, msg, :infinity)

    defp stream_error!(message, _stream) do
      raise Bandit.TransportError, message: message, error: :protocol_error
    end
  end
end
