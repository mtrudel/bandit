defmodule Bandit.HTTP3.Frame do
  @moduledoc false
  # HTTP/3 frame serialization/deserialization (RFC 9114 §7).
  #
  # Wire format per RFC 9114 §7.1:
  #   QUIC variable-length integer: frame type
  #   QUIC variable-length integer: payload length
  #   Payload (payload-length bytes)
  #
  # QUIC variable-length integers per RFC 9000 §A.1:
  #   2-bit prefix in the first byte encodes the total byte count:
  #     0b00 → 1 byte  (6-bit value, max 63)
  #     0b01 → 2 bytes (14-bit value, max 16 383), big-endian
  #     0b10 → 4 bytes (30-bit value, max 1 073 741 823), big-endian
  #     0b11 → 8 bytes (62-bit value), big-endian
  #
  # HTTP/3 frame types we handle (RFC 9114 §7.2):
  #   DATA     0x00  — carries request/response body
  #   HEADERS  0x01  — carries QPACK-encoded header block
  #   SETTINGS 0x04  — connection-level configuration
  #   GOAWAY   0x07  — graceful shutdown
  #
  # All other frame types are represented as {:unknown, type, payload} and
  # must be silently ignored per RFC 9114 §9.

  @data_type 0x00
  @headers_type 0x01
  @settings_type 0x04
  @goaway_type 0x07

  # SETTINGS parameter IDs we care about (RFC 9114 §7.2.4.1 and RFC 9204 §5)
  @settings_qpack_max_table_capacity 0x01
  @settings_max_field_section_size 0x06

  @typedoc "A decoded HTTP/3 frame"
  @type frame ::
          {:data, binary()}
          | {:headers, binary()}
          | {:settings, [{non_neg_integer(), non_neg_integer()}]}
          | {:goaway, non_neg_integer()}
          | {:unknown, non_neg_integer(), binary()}

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @spec serialize(frame()) :: iodata()
  def serialize({:data, data}) do
    payload = IO.iodata_to_binary(data)
    [encode_varint(@data_type), encode_varint(byte_size(payload)), payload]
  end

  def serialize({:headers, block}) do
    block = IO.iodata_to_binary(block)
    [encode_varint(@headers_type), encode_varint(byte_size(block)), block]
  end

  def serialize({:settings, settings}) do
    payload =
      settings
      |> Enum.map(fn {id, val} -> [encode_varint(id), encode_varint(val)] end)
      |> IO.iodata_to_binary()

    [encode_varint(@settings_type), encode_varint(byte_size(payload)), payload]
  end

  def serialize({:goaway, stream_id}) do
    payload = encode_varint(stream_id) |> IO.iodata_to_binary()
    [encode_varint(@goaway_type), encode_varint(byte_size(payload)), payload]
  end

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  @spec deserialize(binary()) ::
          {:ok, frame(), binary()}
          | {:more, binary()}
          | {:error, term()}
  def deserialize(data) do
    case decode_varint(data) do
      {:ok, type, rest} ->
        case decode_varint(rest) do
          {:ok, length, rest} ->
            if byte_size(rest) >= length do
              <<payload::binary-size(length), rest::binary>> = rest
              {:ok, parse_frame(type, payload), rest}
            else
              {:more, data}
            end

          :more ->
            {:more, data}
        end

      :more ->
        {:more, data}
    end
  end

  defp parse_frame(@data_type, payload), do: {:data, payload}
  defp parse_frame(@headers_type, payload), do: {:headers, payload}

  defp parse_frame(@settings_type, payload) do
    case decode_settings(payload, []) do
      {:ok, settings} -> {:settings, settings}
      _ -> {:unknown, @settings_type, payload}
    end
  end

  defp parse_frame(@goaway_type, payload) do
    case decode_varint(payload) do
      {:ok, stream_id, _} -> {:goaway, stream_id}
      _ -> {:unknown, @goaway_type, payload}
    end
  end

  defp parse_frame(type, payload), do: {:unknown, type, payload}

  defp decode_settings(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_settings(data, acc) do
    case decode_varint(data) do
      {:ok, id, rest} ->
        case decode_varint(rest) do
          {:ok, val, rest} -> decode_settings(rest, [{id, val} | acc])
          :more -> {:error, :truncated_settings}
        end

      :more ->
        {:error, :truncated_settings}
    end
  end

  # ---------------------------------------------------------------------------
  # QUIC variable-length integers (RFC 9000 §A.1)
  # ---------------------------------------------------------------------------

  @doc false
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(v) when v <= 63, do: <<0::2, v::6>>
  def encode_varint(v) when v <= 16_383, do: <<1::2, v::14>>
  def encode_varint(v) when v <= 1_073_741_823, do: <<2::2, v::30>>
  def encode_varint(v) when v <= 4_611_686_018_427_387_903, do: <<3::2, v::62>>

  @doc false
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def decode_varint(<<0::2, v::6, rest::binary>>), do: {:ok, v, rest}
  def decode_varint(<<1::2, v::14, rest::binary>>), do: {:ok, v, rest}
  def decode_varint(<<2::2, v::30, rest::binary>>), do: {:ok, v, rest}
  def decode_varint(<<3::2, v::62, rest::binary>>), do: {:ok, v, rest}
  def decode_varint(_), do: :more

  # ---------------------------------------------------------------------------
  # SETTINGS parameter helpers
  # ---------------------------------------------------------------------------

  @doc false
  def settings_qpack_max_table_capacity, do: @settings_qpack_max_table_capacity

  @doc false
  def settings_max_field_section_size, do: @settings_max_field_section_size
end
