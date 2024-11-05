defmodule Bandit.WebSocket.Frame do
  @moduledoc false

  alias Bandit.WebSocket.Frame

  @behaviour Bandit.Extractor

  @typedoc "Indicates an opcode"
  @type opcode ::
          (binary :: 0x2)
          | (connection_close :: 0x8)
          | (continuation :: 0x0)
          | (ping :: 0x9)
          | (pong :: 0xA)
          | (text :: 0x1)

  @typedoc "A valid WebSocket frame"
  @type frame ::
          Frame.Continuation.t()
          | Frame.Text.t()
          | Frame.Binary.t()
          | Frame.ConnectionClose.t()
          | Frame.Ping.t()
          | Frame.Pong.t()

  @impl Bandit.Extractor
  @spec header_and_payload_length(binary(), non_neg_integer()) ::
          {:ok, {header_length :: integer(), payload_length :: integer()}}
          | {:error, :max_frame_size_exceeded | :client_frame_without_mask}
          | :more
  def header_and_payload_length(
        <<_fin::1, _compressed::1, _rsv::2, _opcode::4, 1::1, 127::7, length::64, _mask::32,
          _rest::binary>>,
        max_frame_size
      ) do
    validate_max_frame_size(14, length, max_frame_size)
  end

  def header_and_payload_length(
        <<_fin::1, _compressed::1, _rsv::2, _opcode::4, 1::1, 126::7, length::16, _mask::32,
          _rest::binary>>,
        max_frame_size
      ) do
    validate_max_frame_size(8, length, max_frame_size)
  end

  def header_and_payload_length(
        <<_fin::1, _compressed::1, _rsv::2, _opcode::4, 1::1, length::7, _mask::32,
          _rest::binary>>,
        max_frame_size
      )
      when length <= 125 do
    validate_max_frame_size(6, length, max_frame_size)
  end

  def header_and_payload_length(
        <<_fin::1, _compressed::1, _rsv::2, _opcode::4, 0::1, _rest::binary>>,
        _max_frame_size
      ) do
    {:error, :client_frame_without_mask}
  end

  def header_and_payload_length(_msg, _max_frame_size) do
    :more
  end

  defp validate_max_frame_size(header_length, payload_length, max_frame_size) do
    if max_frame_size != 0 and header_length + payload_length > max_frame_size do
      {:error, :max_frame_size_exceeded}
    else
      {:ok, {header_length, payload_length}}
    end
  end

  @impl Bandit.Extractor
  @spec deserialize(binary(), module()) :: {:ok, frame()} | {:error, term()}
  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, 127::7, length::64, mask::32,
          payload::binary-size(length)>>,
        primitive_ops_module
      ) do
    to_frame(fin, compressed, rsv, opcode, mask, payload, primitive_ops_module)
  end

  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, 126::7, length::16, mask::32,
          payload::binary-size(length)>>,
        primitive_ops_module
      ) do
    to_frame(fin, compressed, rsv, opcode, mask, payload, primitive_ops_module)
  end

  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, length::7, mask::32,
          payload::binary-size(length)>>,
        primitive_ops_module
      ) do
    to_frame(fin, compressed, rsv, opcode, mask, payload, primitive_ops_module)
  end

  def deserialize(_msg, _primitive_ops_module) do
    {:error, :deserialization_failed}
  end

  def recv_metrics(%frame_type{} = frame) do
    case frame_type do
      Frame.Continuation ->
        [
          recv_continuation_frame_count: 1,
          recv_continuation_frame_bytes: IO.iodata_length(frame.data)
        ]

      Frame.Text ->
        [recv_text_frame_count: 1, recv_text_frame_bytes: IO.iodata_length(frame.data)]

      Frame.Binary ->
        [recv_binary_frame_count: 1, recv_binary_frame_bytes: IO.iodata_length(frame.data)]

      Frame.ConnectionClose ->
        [
          recv_connection_close_frame_count: 1,
          recv_connection_close_frame_bytes: IO.iodata_length(frame.reason)
        ]

      Frame.Ping ->
        [recv_ping_frame_count: 1, recv_ping_frame_bytes: IO.iodata_length(frame.data)]

      Frame.Pong ->
        [recv_pong_frame_count: 1, recv_pong_frame_bytes: IO.iodata_length(frame.data)]
    end
  end

  def send_metrics(%frame_type{} = frame) do
    case frame_type do
      Frame.Continuation ->
        [
          send_continuation_frame_count: 1,
          send_continuation_frame_bytes: IO.iodata_length(frame.data)
        ]

      Frame.Text ->
        [send_text_frame_count: 1, send_text_frame_bytes: IO.iodata_length(frame.data)]

      Frame.Binary ->
        [send_binary_frame_count: 1, send_binary_frame_bytes: IO.iodata_length(frame.data)]

      Frame.ConnectionClose ->
        [
          send_connection_close_frame_count: 1,
          send_connection_close_frame_bytes: IO.iodata_length(frame.reason)
        ]

      Frame.Ping ->
        [send_ping_frame_count: 1, send_ping_frame_bytes: IO.iodata_length(frame.data)]

      Frame.Pong ->
        [send_pong_frame_count: 1, send_pong_frame_bytes: IO.iodata_length(frame.data)]
    end
  end

  defp to_frame(_fin, _compressed, rsv, _opcode, _mask, _payload, _primitive_ops_module)
       when rsv != 0x0 do
    {:error, "Received unsupported RSV flags #{rsv}"}
  end

  defp to_frame(fin, compressed, 0x0, opcode, mask, payload, primitive_ops_module) do
    fin = fin == 0x1
    compressed = compressed == 0x1
    unmasked_payload = primitive_ops_module.ws_mask(payload, mask)

    opcode
    |> case do
      0x0 -> Frame.Continuation.deserialize(fin, compressed, unmasked_payload)
      0x1 -> Frame.Text.deserialize(fin, compressed, unmasked_payload)
      0x2 -> Frame.Binary.deserialize(fin, compressed, unmasked_payload)
      0x8 -> Frame.ConnectionClose.deserialize(fin, compressed, unmasked_payload)
      0x9 -> Frame.Ping.deserialize(fin, compressed, unmasked_payload)
      0xA -> Frame.Pong.deserialize(fin, compressed, unmasked_payload)
      unknown -> {:error, "unknown opcode #{unknown}"}
    end
  end

  defprotocol Serializable do
    @moduledoc false

    @spec serialize(any()) :: [{Frame.opcode(), boolean(), boolean(), iodata()}]
    def serialize(frame)
  end

  @spec serialize(frame()) :: iolist()
  def serialize(frame) do
    frame
    |> Serializable.serialize()
    |> Enum.map(fn {opcode, fin, compressed, payload} ->
      fin = if fin, do: 0x1, else: 0x0
      compressed = if compressed, do: 0x1, else: 0x0
      mask_and_length = payload |> IO.iodata_length() |> mask_and_length()
      [<<fin::1, compressed::1, 0x0::2, opcode::4>>, mask_and_length, payload]
    end)
  end

  defp mask_and_length(length) when length <= 125, do: <<0::1, length::7>>
  defp mask_and_length(length) when length <= 65_535, do: <<0::1, 126::7, length::16>>
  defp mask_and_length(length), do: <<0::1, 127::7, length::64>>
end
