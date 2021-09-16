defmodule Bandit.HTTP2.Settings do
  @moduledoc """
  Settings as defined in RFC7540§6.5.2 and §11.3
  """

  defstruct header_table_size: 4_096,
            enable_push: true,
            max_concurrent_streams: :infinity,
            initial_window_size: 65_535,
            max_frame_size: 16_384,
            max_header_list_size: :infinity
end
