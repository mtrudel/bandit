defmodule Bandit.WebSocket.Extractor do
  @moduledoc false
  # A state machine for efficiently extracting full frames from received packets

  alias Bandit.WebSocket.Frame

  @type t :: %__MODULE__{
          header: binary(),
          payload: iodata(),
          payload_length: non_neg_integer(),
          required_length: non_neg_integer(),
          mode: :header_parsing | :payload_parsing,
          max_frame_size: non_neg_integer()
        }

  defstruct header: <<>>,
            payload: [],
            payload_length: 0,
            required_length: 0,
            mode: :header_parsing,
            max_frame_size: 0

  @spec new(Keyword.t()) :: t()
  def new(opts) do
    max_frame_size = Keyword.get(opts, :max_frame_size, 0)

    %__MODULE__{
      max_frame_size: max_frame_size
    }
  end

  @spec push_data(t(), binary()) :: t()
  def push_data(%__MODULE__{} = state, data) do
    case state do
      %{mode: :header_parsing} ->
        %{state | header: state.header <> data}

      %{mode: :payload_parsing, payload: payload, payload_length: length} ->
        %{state | payload: [payload, data], payload_length: length + byte_size(data)}
    end
  end

  @spec pop_frame(t()) :: {t(), {:ok, Frame.frame()} | {:error, term()} | :more}
  def pop_frame(state)

  def pop_frame(%__MODULE__{mode: :header_parsing} = state) do
    case Frame.header_and_payload_length(state.header, state.max_frame_size) do
      {:ok, {header_length, required_length}} ->
        state
        |> transition_to_payload_parsing(header_length, required_length)
        |> pop_frame()

      {:error, message} ->
        {state, {:error, message}}

      :more ->
        {state, :more}
    end
  end

  def pop_frame(%__MODULE__{mode: :payload_parsing} = state) do
    if state.payload_length >= state.required_length do
      <<payload::binary-size(state.required_length), rest::binary>> =
        IO.iodata_to_binary(state.payload)

      frame = Frame.deserialize(state.header <> payload)
      state = transition_to_header_parsing(state, rest)

      {state, frame}
    else
      {state, :more}
    end
  end

  defp transition_to_payload_parsing(state, header_length, required_length) do
    payload_length = byte_size(state.header) - header_length

    state
    |> Map.put(:header, binary_part(state.header, 0, header_length))
    |> Map.put(:payload, binary_part(state.header, header_length, payload_length))
    |> Map.put(:payload_length, payload_length)
    |> Map.put(:required_length, required_length)
    |> Map.put(:mode, :payload_parsing)
  end

  defp transition_to_header_parsing(state, rest) do
    state
    |> Map.put(:header, rest)
    |> Map.put(:payload, [])
    |> Map.put(:payload_length, 0)
    |> Map.put(:required_length, 0)
    |> Map.put(:mode, :header_parsing)
  end
end
