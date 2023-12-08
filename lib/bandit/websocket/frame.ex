defmodule Bandit.WebSocket.Frame do
  @moduledoc false

  alias Bandit.WebSocket.Frame

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

  @spec deserialize(binary(), non_neg_integer()) ::
          {{:ok, frame()}, iodata()}
          | {{:more, binary()}, <<>>}
          | {{:error, term()}, iodata()}
          | nil
  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, 127::7, length::64, mask::32,
          payload::binary-size(length), rest::binary>>,
        max_frame_size
      )
      when max_frame_size == 0 or length <= max_frame_size do
    to_frame(fin, compressed, rsv, opcode, mask, payload, rest)
  end

  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, 126::7, length::16, mask::32,
          payload::binary-size(length), rest::binary>>,
        max_frame_size
      )
      when max_frame_size == 0 or length <= max_frame_size do
    to_frame(fin, compressed, rsv, opcode, mask, payload, rest)
  end

  def deserialize(
        <<fin::1, compressed::1, rsv::2, opcode::4, 1::1, length::7, mask::32,
          payload::binary-size(length), rest::binary>>,
        max_frame_size
      )
      when length <= 125 and (max_frame_size == 0 or length <= max_frame_size) do
    to_frame(fin, compressed, rsv, opcode, mask, payload, rest)
  end

  # nil is used to indicate for Stream.unfold/2 that the frame deserialization is finished
  def deserialize(<<>>, _max_frame_size) do
    nil
  end

  def deserialize(msg, max_frame_size)
      when max_frame_size != 0 and byte_size(msg) > max_frame_size do
    {{:error, :max_frame_size_exceeded}, msg}
  end

  def deserialize(msg, _max_frame_size) do
    {{:more, msg}, <<>>}
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

  defp to_frame(_fin, _compressed, rsv, _opcode, _mask, _payload, rest) when rsv != 0x0 do
    {{:error, "Received unsupported RSV flags #{rsv}"}, rest}
  end

  defp to_frame(fin, compressed, 0x0, opcode, mask, payload, rest) do
    fin = fin == 0x1
    compressed = compressed == 0x1
    unmasked_payload = mask(payload, mask)

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
    |> case do
      {:ok, frame} -> {{:ok, frame}, rest}
      {:error, reason} -> {{:error, reason}, rest}
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

  # Masking is done @mask_size bits at a time until there is less than that number of bits left.
  # We then go 32 bits at a time until there is less than 32 bits left. We then go 8 bits at
  # a time. This yields some significant perforamnce gains for only marginally more complexity
  @mask_size 512

  # Note that masking is an involution, so we don't need a separate unmask function
  def mask(payload, mask) when bit_size(payload) >= @mask_size do
    payload
    |> do_mask(String.duplicate(<<mask::32>>, div(@mask_size, 32)), [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # Note that we assume the mask integer is 32-bits and do not check.
  @spec mask(binary(), integer()) :: binary()
  def mask(payload, mask_integer) do
    payload_size = byte_size(payload)
    count_4_bytes = div(payload_size, 4)

    mask_repetitions = if rem(payload_size, 4) == 0, do: count_4_bytes, else: count_4_bytes + 1

    fit_mask =
      <<mask_integer::32>>
      |> :binary.copy(mask_repetitions)
      |> :binary.part(0, payload_size)

    :crypto.exor(payload, fit_mask)
  end
end
