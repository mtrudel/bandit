defmodule Bandit.Extractor do
  @moduledoc false
  # A state machine for efficiently extracting full frames from received packets

  @type deserialize_result :: any()

  @callback header_and_payload_length(binary(), max_frame_size :: integer()) ::
              {:ok, {header_length :: integer(), payload_length :: integer()}}
              | {:error, term()}
              | :more

  @callback deserialize(binary(), primitive_ops_module :: module()) :: deserialize_result()

  @type t :: %__MODULE__{
          header: binary(),
          payload: iodata(),
          payload_pending: iodata(),
          payload_pending_count: non_neg_integer(),
          payload_length: non_neg_integer(),
          required_length: non_neg_integer(),
          mode: :header_parsing | :payload_parsing,
          max_frame_size: non_neg_integer(),
          frame_parser: atom(),
          primitive_ops_module: module()
        }

  defstruct header: <<>>,
            payload: [],
            payload_pending: [],
            payload_pending_count: 0,
            payload_length: 0,
            required_length: 0,
            mode: :header_parsing,
            max_frame_size: 0,
            frame_parser: nil,
            primitive_ops_module: nil

  # The maximum number of received packets that are kept as separate binaries before they are
  # copied into one binary. A peer that sends a large frame as many 1 byte packets could otherwise
  # make us keep about 40 bytes of memory for each byte of payload. Each batch is copied one time
  # only, so the frame is put together in linear time
  @max_pending_packets 1024

  @spec new(module(), module(), Keyword.t()) :: t()
  def new(frame_parser, primitive_ops_module, opts) do
    max_frame_size = Keyword.get(opts, :max_frame_size, 8_000_000)

    %__MODULE__{
      max_frame_size: max_frame_size,
      frame_parser: frame_parser,
      primitive_ops_module: primitive_ops_module
    }
  end

  @spec push_data(t(), binary()) :: t()
  def push_data(%__MODULE__{} = state, data) do
    case state do
      %{mode: :header_parsing} ->
        %{state | header: state.header <> data}

      %{mode: :payload_parsing} ->
        %{
          state
          | payload_pending: [state.payload_pending, data],
            payload_pending_count: state.payload_pending_count + 1,
            payload_length: state.payload_length + byte_size(data)
        }
        |> maybe_coalesce_payload()
    end
  end

  defp maybe_coalesce_payload(%{payload_pending_count: count} = state)
       when count >= @max_pending_packets do
    chunk = IO.iodata_to_binary(state.payload_pending)
    %{state | payload: [state.payload, chunk], payload_pending: [], payload_pending_count: 0}
  end

  defp maybe_coalesce_payload(state), do: state

  @spec pop_frame(t()) :: {t(), :more | deserialize_result()}
  def pop_frame(state)

  def pop_frame(%__MODULE__{mode: :header_parsing} = state) do
    case state.frame_parser.header_and_payload_length(state.header, state.max_frame_size) do
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

  def pop_frame(
        %__MODULE__{
          mode: :payload_parsing,
          payload_length: payload_length,
          required_length: required_length
        } = state
      ) do
    if payload_length >= required_length do
      # When nothing is pending, state.payload can be the binary from the packet that held the
      # header. Do not wrap it in a list, because IO.iodata_to_binary/1 returns a binary as is but
      # copies a list. A copy for each frame would make a packet of many small frames quadratic
      buffer =
        case state.payload_pending do
          [] -> IO.iodata_to_binary(state.payload)
          pending -> IO.iodata_to_binary([state.payload, pending])
        end

      <<payload::binary-size(^required_length), rest::binary>> = buffer

      frame = state.frame_parser.deserialize(state.header <> payload, state.primitive_ops_module)
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
    |> Map.put(:payload_pending, [])
    |> Map.put(:payload_pending_count, 0)
    |> Map.put(:payload_length, 0)
    |> Map.put(:required_length, 0)
    |> Map.put(:mode, :header_parsing)
  end
end
