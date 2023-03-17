defmodule Bandit.HTTP2.FlowControl do
  @moduledoc false
  # Helpers for working with flow control window calculations

  import Bitwise

  @max_window_increment (1 <<< 31) - 1
  @max_window_size (1 <<< 31) - 1
  @min_window_size 1 <<< 30

  @spec compute_recv_window(non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def compute_recv_window(recv_window_size, data_size) do
    # This is what our window size will be after receiving data_size bytes
    recv_window_size = recv_window_size - data_size

    if recv_window_size > @min_window_size do
      # We have room to go before we need to update our window
      {recv_window_size, 0}
    else
      # We want our new window to be as large as possible, but are limited by both the maximum size
      # of the window (2^31-1) and the maximum size of the increment we can send to the client, both
      # per RFC9113§6.9. Be careful about handling cases where we have a negative window due to
      # misbehaving clients or network races
      new_recv_window_size = min(recv_window_size + @max_window_increment, @max_window_size)

      # Finally, determine what increment to send to the client
      increment = new_recv_window_size - recv_window_size

      {new_recv_window_size, increment}
    end
  end

  @spec update_send_window(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_send_window(current_send_window, increment) do
    if current_send_window + increment > @max_window_size do
      {:error, "Invalid WINDOW_UPDATE increment RFC9113§6.9.1"}
    else
      {:ok, current_send_window + increment}
    end
  end
end
