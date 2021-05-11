defmodule Bandit.HTTP2.Frame.Setting do
  defstruct ack: false, settings: %{}

  def build(<<_flags::7, 0x0::1>>, 0, payload) do
    payload
    |> parse_settings()
    |> case do
      {:ok, settings} -> {:ok, %__MODULE__{ack: false, settings: settings}}
      :error -> {:error, 0, :FRAME_SIZE_ERROR, "Invalid SETTINGS payload (RFC7540§6.5)"}
    end
  end

  def build(<<_flags::7, 0x1::1>>, 0, <<>>) do
    {:ok, %__MODULE__{ack: true}}
  end

  def build(<<_flags::7, 0x1::1>>, _stream_id, _payload) do
    {:error, 0, :FRAME_SIZE_ERROR, "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}
  end

  def build(_flags, _stream_id, _payload) do
    {:error, 0, :PROTOCOL_ERROR, "Invalid SETTINGS frame (RFC7540§6.5)"}
  end

  defp parse_settings(payload) do
    payload
    |> Stream.unfold(fn
      <<>> -> nil
      <<setting::16, value::32, rest::binary>> -> {{:ok, {setting, value}}, rest}
      <<rest::binary>> -> {{:error, rest}, <<>>}
    end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {setting, value}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, setting, value)}}
      {:error, _rest}, _acc -> {:halt, :error}
    end)
  end
end
