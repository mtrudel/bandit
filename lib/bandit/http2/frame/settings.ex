defmodule Bandit.HTTP2.Frame.Settings do
  @moduledoc false

  import Bandit.HTTP2.Frame.Flags
  import Bitwise

  @max_window_size (1 <<< 31) - 1
  @min_frame_size 1 <<< 14
  @max_frame_size (1 <<< 24) - 1

  defstruct ack: false, settings: nil

  @typedoc "An HTTP/2 SETTINGS frame"
  @type t :: %__MODULE__{ack: true, settings: nil} | %__MODULE__{ack: false, settings: map()}

  @ack_bit 0

  @spec deserialize(Bandit.HTTP2.Frame.flags(), Bandit.HTTP2.Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Bandit.HTTP2.Errors.error_code(), binary()}
  def deserialize(flags, 0, payload) when clear?(flags, @ack_bit) do
    payload
    |> Stream.unfold(fn
      <<>> -> nil
      <<setting::16, value::32, rest::binary>> -> {{:ok, {setting, value}}, rest}
      <<rest::binary>> -> {{:error, rest}, <<>>}
    end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {0x01, value}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :header_table_size, value)}}

      {:ok, {0x02, val}}, {:ok, acc} when val in [0x00, 0x01] ->
        {:cont, {:ok, acc}}

      {:ok, {0x02, _value}}, {:ok, _acc} ->
        {:halt,
         {:error, Bandit.HTTP2.Errors.protocol_error(), "Invalid enable_push value (RFC9113§6.5)"}}

      {:ok, {0x03, value}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :max_concurrent_streams, value)}}

      {:ok, {0x04, value}}, {:ok, _acc} when value > @max_window_size ->
        {:halt,
         {:error, Bandit.HTTP2.Errors.flow_control_error(), "Invalid window_size (RFC9113§6.5)"}}

      {:ok, {0x04, value}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :initial_window_size, value)}}

      {:ok, {0x05, value}}, {:ok, _acc} when value < @min_frame_size ->
        {:halt,
         {:error, Bandit.HTTP2.Errors.frame_size_error(), "Invalid max_frame_size (RFC9113§6.5)"}}

      {:ok, {0x05, value}}, {:ok, _acc} when value > @max_frame_size ->
        {:halt,
         {:error, Bandit.HTTP2.Errors.frame_size_error(), "Invalid max_frame_size (RFC9113§6.5)"}}

      {:ok, {0x05, value}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :max_frame_size, value)}}

      {:ok, {0x06, value}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :max_header_list_size, value)}}

      {:ok, {_setting, _value}}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {:error, _rest}, _acc ->
        {:halt,
         {:error, Bandit.HTTP2.Errors.frame_size_error(), "Invalid SETTINGS size (RFC9113§6.5)"}}
    end)
    |> case do
      {:ok, settings} -> {:ok, %__MODULE__{ack: false, settings: settings}}
      {:error, error_code, reason} -> {:error, error_code, reason}
    end
  end

  def deserialize(flags, 0, <<>>) when set?(flags, @ack_bit) do
    {:ok, %__MODULE__{ack: true}}
  end

  def deserialize(flags, 0, _payload) when set?(flags, @ack_bit) do
    {:error, Bandit.HTTP2.Errors.frame_size_error(),
     "SETTINGS ack frame with non-empty payload (RFC9113§6.5)"}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, Bandit.HTTP2.Errors.protocol_error(), "Invalid SETTINGS frame (RFC9113§6.5)"}
  end

  defimpl Bandit.HTTP2.Frame.Serializable do
    @ack_bit 0

    def serialize(%Bandit.HTTP2.Frame.Settings{ack: true}, _max_frame_size),
      do: [{0x4, set([@ack_bit]), 0, <<>>}]

    def serialize(%Bandit.HTTP2.Frame.Settings{ack: false} = frame, _max_frame_size) do
      # Encode default settings values as empty binaries so that we do not send
      # them. This means we can't restore settings back to default values if we
      # change them, but since we don't ever change our settings this is fine
      payload =
        frame.settings
        |> Enum.uniq_by(fn {setting, _} -> setting end)
        |> Enum.map(fn
          {:header_table_size, 4_096} -> <<>>
          {:header_table_size, value} -> <<0x01::16, value::32>>
          {:max_concurrent_streams, :infinity} -> <<>>
          {:max_concurrent_streams, value} -> <<0x03::16, value::32>>
          {:initial_window_size, 65_535} -> <<>>
          {:initial_window_size, value} -> <<0x04::16, value::32>>
          {:max_frame_size, 16_384} -> <<>>
          {:max_frame_size, value} -> <<0x05::16, value::32>>
          {:max_header_list_size, :infinity} -> <<>>
          {:max_header_list_size, value} -> <<0x06::16, value::32>>
        end)

      [{0x4, 0x0, 0, payload}]
    end
  end
end
