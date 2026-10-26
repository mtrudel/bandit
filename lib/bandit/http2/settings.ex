defmodule Bandit.HTTP2.Settings do
  @moduledoc """
  Settings as defined in RFC9113§6.5.2
  """

  defstruct header_table_size: 4_096,
            max_concurrent_streams: 500,
            initial_window_size: 65_535,
            max_frame_size: 16_384,
            max_header_list_size: 262_144

  @typedoc "A collection of settings as defined in RFC9113§6.5"
  @type t :: %__MODULE__{
          header_table_size: non_neg_integer(),
          max_concurrent_streams: non_neg_integer() | :infinity,
          initial_window_size: non_neg_integer(),
          max_frame_size: non_neg_integer(),
          max_header_list_size: non_neg_integer() | :infinity
        }
end
