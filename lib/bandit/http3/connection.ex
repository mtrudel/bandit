defmodule Bandit.HTTP3.Connection do
  @moduledoc false
  # Process-free HTTP/3 connection state managed by `Bandit.HTTP3.Handler`.
  #
  # Responsibilities:
  #   - Tracking per-stream pids and per-stream data buffers
  #   - Parsing HTTP/3 frames from the raw byte stream delivered by QUIC
  #   - Spawning `Bandit.HTTP3.StreamProcess` for each client request stream
  #   - Buffering and parsing the client's control stream (SETTINGS, GOAWAY)
  #   - Routing decoded header/data frames to the appropriate stream process

  require Logger

  import Bitwise, only: [band: 2]

  # QUIC stream type bits (RFC 9000 §2.1): low 2 bits of stream ID
  # 0b00 (0) = client-initiated bidirectional  → HTTP/3 request stream
  # 0b01 (1) = server-initiated bidirectional  → (not used in HTTP/3)
  # 0b10 (2) = client-initiated unidirectional → control / QPACK streams
  # 0b11 (3) = server-initiated unidirectional → our control stream

  @request_stream_type 0
  @client_uni_type 2

  # First byte of an HTTP/3 unidirectional stream declares the stream type
  # (RFC 9114 §6.2):
  @h3_control_stream_type 0x00
  @qpack_encoder_type 0x02
  @qpack_decoder_type 0x03

  defstruct plug: nil,
            opts: %{},
            # stream_id => pid  (active request streams)
            streams: %{},
            # stream_id => binary  (accumulated raw bytes for request streams)
            stream_bufs: %{},
            # {secure?, peer_ip}
            conn_data: nil,
            # Bandit.Telemetry.t()
            telemetry_span: nil,
            # accumulated bytes from the client's unidirectional control stream
            control_buf: <<>>,
            # true once we've consumed the stream-type byte from the control stream
            control_stream_started: false

  @type t :: %__MODULE__{}

  # ---------------------------------------------------------------------------
  # init/4  — called from Handler after connection is established
  # ---------------------------------------------------------------------------

  @spec init(
          Bandit.Pipeline.plug_def(),
          map(),
          Bandit.Pipeline.conn_data(),
          Bandit.Telemetry.t()
        ) :: t()
  def init(plug, opts, conn_data, telemetry_span) do
    %__MODULE__{
      plug: plug,
      opts: opts,
      conn_data: conn_data,
      telemetry_span: telemetry_span
    }
  end

  # ---------------------------------------------------------------------------
  # handle_stream_opened/3  — called when QUIC reports a new stream
  # ---------------------------------------------------------------------------

  @spec handle_stream_opened(non_neg_integer(), pid(), t()) :: t()
  def handle_stream_opened(stream_id, handler_pid, connection) do
    case band(stream_id, 0x3) do
      @request_stream_type ->
        # Client-initiated bidirectional stream: HTTP/3 request
        spawn_request_stream(stream_id, handler_pid, connection)

      @client_uni_type ->
        # Client-initiated unidirectional stream: control / QPACK; nothing to
        # spawn — data arrives via handle_stream_data and is buffered/parsed.
        connection

      _ ->
        connection
    end
  end

  defp spawn_request_stream(stream_id, handler_pid, connection) do
    stream = Bandit.HTTP3.Stream.init(handler_pid, stream_id)

    case Bandit.HTTP3.StreamProcess.start_link(
           stream,
           connection.plug,
           connection.telemetry_span,
           connection.conn_data,
           connection.opts
         ) do
      {:ok, pid} ->
        %{connection | streams: Map.put(connection.streams, stream_id, pid)}

      _ ->
        Logger.error("HTTP/3: failed to start stream process for stream #{stream_id}")
        connection
    end
  end

  # ---------------------------------------------------------------------------
  # handle_stream_data/4  — called when QUIC delivers bytes on a stream
  # ---------------------------------------------------------------------------

  @spec handle_stream_data(non_neg_integer(), binary(), boolean(), t()) :: t()
  def handle_stream_data(stream_id, data, fin, connection) do
    case Map.get(connection.streams, stream_id) do
      nil ->
        # Unidirectional stream (control / QPACK): buffer and parse
        handle_unidirectional_data(stream_id, data, fin, connection)

      pid ->
        # Request stream: accumulate bytes and deliver complete HTTP/3 frames
        handle_request_data(stream_id, data, fin, pid, connection)
    end
  end

  defp handle_request_data(stream_id, data, fin, pid, connection) do
    buf = Map.get(connection.stream_bufs, stream_id, <<>>) <> data

    case drain_request_frames(buf, fin, pid) do
      {:ok, rest} ->
        bufs = Map.put(connection.stream_bufs, stream_id, rest)
        %{connection | stream_bufs: bufs}

      {:error, reason} ->
        Logger.warning("HTTP/3 request stream #{stream_id} frame error: #{inspect(reason)}",
          domain: [:bandit]
        )

        connection
    end
  end

  defp drain_request_frames(buf, fin, pid) do
    case Bandit.HTTP3.Frame.deserialize(buf) do
      {:ok, {:headers, block}, rest} ->
        case Bandit.HTTP3.QPACK.decode_headers(block) do
          {:ok, headers} ->
            end_stream = fin && rest == <<>>
            Bandit.HTTP3.Stream.deliver_headers(pid, headers, end_stream)
            drain_request_frames(rest, fin, pid)

          {:error, reason} ->
            {:error, {:qpack, reason}}
        end

      {:ok, {:data, body}, rest} ->
        end_stream = fin && rest == <<>>
        Bandit.HTTP3.Stream.deliver_data(pid, body, end_stream)
        drain_request_frames(rest, fin, pid)

      {:ok, {:unknown, _type, _payload}, rest} ->
        # Unknown frame types MUST be ignored (RFC 9114 §9)
        drain_request_frames(rest, fin, pid)

      {:ok, _other, rest} ->
        drain_request_frames(rest, fin, pid)

      {:more, remaining} ->
        if fin && remaining != <<>> do
          Logger.warning("HTTP/3: FIN received with partial frame data; discarding",
            domain: [:bandit]
          )
        end

        {:ok, if(fin, do: <<>>, else: remaining)}
    end
  end

  defp handle_unidirectional_data(_stream_id, data, _fin, connection) do
    # Consume the stream-type byte on first data for this unidirectional stream,
    # then parse HTTP/3 frames from the rest (we only care about SETTINGS).
    buf = connection.control_buf <> data

    {buf, started} =
      if connection.control_stream_started do
        {buf, true}
      else
        case buf do
          <<@h3_control_stream_type, rest::binary>> -> {rest, true}
          <<@qpack_encoder_type, rest::binary>> -> {rest, true}
          <<@qpack_decoder_type, rest::binary>> -> {rest, true}
          # Unknown unidirectional stream type — consume silently
          <<_type, rest::binary>> -> {rest, true}
          _ -> {buf, false}
        end
      end

    buf = drain_control_frames(buf)
    %{connection | control_buf: buf, control_stream_started: started}
  end

  defp drain_control_frames(buf) do
    case Bandit.HTTP3.Frame.deserialize(buf) do
      {:ok, {:settings, _settings}, rest} ->
        # Peer settings received. Static-QPACK needs no action here.
        drain_control_frames(rest)

      {:ok, {:goaway, _stream_id}, rest} ->
        drain_control_frames(rest)

      {:ok, _other, rest} ->
        drain_control_frames(rest)

      {:more, remaining} ->
        remaining
    end
  end

  # ---------------------------------------------------------------------------
  # stream_terminated/2  — called when a StreamProcess exits
  # ---------------------------------------------------------------------------

  @spec stream_terminated(pid(), t()) :: t()
  def stream_terminated(pid, connection) do
    streams = connection.streams |> Enum.reject(fn {_, v} -> v == pid end) |> Map.new()
    %{connection | streams: streams}
  end
end
