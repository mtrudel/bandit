defmodule Bandit.HTTP2.Frame.Settings do
  @moduledoc false

  defstruct ack: false, settings: %{}

  alias Bandit.HTTP2.Constants

  def deserialize(<<_flags::7, 0x0::1>>, 0, payload) do
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
    |> case do
      {:ok, settings} ->
        {:ok, %__MODULE__{ack: false, settings: settings}}

      :error ->
        {:error, 0, Constants.frame_size_error(), "Invalid SETTINGS payload (RFC7540§6.5)"}
    end
  end

  def deserialize(<<_flags::7, 0x1::1>>, 0, <<>>) do
    {:ok, %__MODULE__{ack: true}}
  end

  def deserialize(<<_flags::7, 0x1::1>>, 0, _payload) do
    {:error, 0, Constants.frame_size_error(),
     "SETTINGS ack frame with non-empty payload (RFC7540§6.5)"}
  end

  def deserialize(_flags, _stream_id, _payload) do
    {:error, 0, Constants.protocol_error(), "Invalid SETTINGS frame (RFC7540§6.5)"}
  end

  defimpl Serializable do
    alias Bandit.HTTP2.Frame.Settings

    def serialize(%Settings{ack: true}), do: {0x4, <<0x1>>, 0, <<>>}

    def serialize(%Settings{ack: false, settings: settings}) do
      payload =
        settings
        |> Enum.reduce(<<>>, fn {setting, value}, acc -> acc <> <<setting::16, value::32>> end)

      {0x4, <<0x0>>, 0, payload}
    end
  end
end
