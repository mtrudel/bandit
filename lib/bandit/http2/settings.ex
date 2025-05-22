defmodule Bandit.HTTP2.Settings do
  @moduledoc """
  Settings as defined in RFC9113§6.5.2
  """

  defstruct header_table_size: nil,
            max_concurrent_streams: nil,
            initial_window_size: nil,
            max_frame_size: nil,
            max_header_list_size: nil

  @default %{
    header_table_size: 4_096,
    max_concurrent_streams: :infinity,
    initial_window_size: 65_535,
    max_frame_size: 16_384,
    max_header_list_size: :infinity
  }

  @typedoc "A collection of settings as defined in RFC9113§6.5"
  @type t :: %__MODULE__{
          header_table_size: non_neg_integer() | nil,
          max_concurrent_streams: non_neg_integer() | :infinity | nil,
          initial_window_size: non_neg_integer() | nil,
          max_frame_size: non_neg_integer() | nil,
          max_header_list_size: non_neg_integer() | :infinity | nil
        }

  def default, do: struct(Bandit.HTTP2.Settings, @default)

  def to_default(%__MODULE__{} = struct) do
    %__MODULE__{
      header_table_size: struct.header_table_size || @default.header_table_size,
      max_concurrent_streams: struct.max_concurrent_streams || @default.max_concurrent_streams,
      initial_window_size: struct.initial_window_size || @default.initial_window_size,
      max_frame_size: struct.max_frame_size || @default.max_frame_size,
      max_header_list_size: struct.max_header_list_size || @default.max_header_list_size
    }
  end

  def merge(nil, right), do: right |> to_default()
  def merge(left, nil), do: left |> to_default()

  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      header_table_size:
        left.header_table_size || right.header_table_size || @default.header_table_size,
      max_concurrent_streams:
        left.max_concurrent_streams || right.max_concurrent_streams ||
          @default.max_concurrent_streams,
      initial_window_size:
        left.initial_window_size || right.initial_window_size || @default.initial_window_size,
      max_frame_size: left.max_frame_size || right.max_frame_size || @default.max_frame_size,
      max_header_list_size:
        left.max_header_list_size || right.max_header_list_size || @default.max_header_list_size
    }
  end
end
