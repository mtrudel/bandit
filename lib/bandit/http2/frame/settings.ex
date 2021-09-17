defmodule Bandit.HTTP2.Frame.Settings do
  @moduledoc false

  defstruct ack: false, settings: nil

  import Bitwise

  alias Bandit.HTTP2.Constants

  def deserialize(flags, 0, payload) when (flags &&& 0x1) == 0x0 do
    payload
    |> Stream.unfold(fn
      <<>> -> nil
      <<setting::16, value::32, rest::binary>> -> {{:ok, {setting, value}}, rest}
      <<rest::binary>> -> {{:error, rest}, <<>>}
    end)
    |> Enum.reduce_while({:ok, %Bandit.HTTP2.Settings{}}, fn
      {:ok, {0x01, value}}, {:ok, acc} -> {:cont, {:ok, %{acc | header_table_size: value}}}
      {:ok, {0x02, 0x01}}, {:ok, acc} -> {:cont, {:ok, %{acc | enable_push: true}}}
      {:ok, {0x02, 0x00}}, {:ok, acc} -> {:cont, {:ok, %{acc | enable_push: false}}}
      {:ok, {0x02, _value}}, {:ok, _acc} -> {:cont, {:error, :invalid_enable_push}}
      {:ok, {0x03, value}}, {:ok, acc} -> {:cont, {:ok, %{acc | max_concurrent_streams: value}}}
      {:ok, {0x04, value}}, {:ok, acc} -> {:cont, {:ok, %{acc | initial_window_size: value}}}
      {:ok, {0x05, value}}, {:ok, acc} -> {:cont, {:ok, %{acc | max_frame_size: value}}}
      {:ok, {0x06, value}}, {:ok, acc} -> {:cont, {:ok, %{acc | max_header_list_size: value}}}
      {:ok, {_setting, _value}}, {:ok, acc} -> {:cont, {:ok, acc}}
      {:error, _rest}, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, settings} ->
        {:ok, %__MODULE__{ack: false, settings: settings}}

      {:error, reason} ->
        {:error, {:connection, Constants.protocol_error(), reason}}

      :error ->
        {:error,
         {:connection, Constants.frame_size_error(), "Invalid SETTINGS payload (RFC7540§6.5)"}}
    end
  end

  def deserialize(flags, 0, <<>>) when (flags &&& 0x1) == 0x1 do
    {:ok, %__MODULE__{ack: true}}
  end

  def deserialize(flags, 0, _payload) when (flags &&& 0x1) == 0x1 do
    {:error,
     {:connection, Constants.frame_size_error(),
      "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, {:connection, Constants.protocol_error(), "Invalid SETTINGS frame (RFC7540§6.5)"}}
  end

  defimpl Bandit.HTTP2.Serializable do
    alias Bandit.HTTP2.Frame.Settings

    def serialize(%Settings{ack: true}, _max_frame_size), do: [{0x4, 0x1, 0, <<>>}]

    def serialize(%Settings{ack: false} = frame, _max_frame_size) do
      # Note that the ordering here corresponds to the keys' alphabetical
      # ordering on the Setting struct. However, we know there are no duplicates
      # in this list so this is not a problem per RFC7540§6.5
      #
      # Encode default settings values as empty binaries so that we do not send
      # them. This means we can't restore settings back to default values if we
      # change them, but since we don't ever change our settings this is fine
      payload =
        frame.settings
        |> Map.from_struct()
        |> Enum.map(fn
          {:header_table_size, 4_096} -> <<>>
          {:header_table_size, value} -> <<0x01::16, value::32>>
          {:enable_push, true} -> <<>>
          {:enable_push, false} -> <<0x02::16, 0x00::32>>
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
