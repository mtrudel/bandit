defmodule Bandit.HTTP2.FlowControl do
  @moduledoc false
  # Helpers for working with flow control window calculations

  import Bitwise

  @max_window_increment (1 <<< 31) - 1
  @max_window_size (1 <<< 31) - 1
  @min_window_size 1 <<< 30

  # The slowest rate (in bytes per second) at which a peer may drain a blocked send before we stop
  # waiting on it. See `extend_send_deadline/4`
  @min_send_rate 1_024

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
          {:ok, non_neg_integer()} | {:error, String.t()}
  def update_send_window(current_send_window, increment) do
    if current_send_window + increment > @max_window_size do
      {:error, "Invalid WINDOW_UPDATE increment RFC9113§6.9.1"}
    else
      {:ok, current_send_window + increment}
    end
  end

  # Sends which block on a send window (connection or stream level) are bounded by a deadline,
  # so that a peer cannot pin the stream process (and any resources it holds) indefinitely.
  #
  # The deadline starts as `timeout` ms after the send first blocks. It is *not* reset when the
  # peer makes progress, since a peer which dribbles tiny window increments (or sends frames that
  # grant nothing at all, such as an empty SETTINGS) would otherwise keep a send blocked forever.
  # Instead, it is pushed back only in proportion to the bytes the peer actually lets us send: one
  # second for every `@min_send_rate` bytes, never beyond `timeout` ms from now (so that credit
  # cannot be banked up). A peer draining at or above `@min_send_rate` (ie: any honest client,
  # however slow) never reaches the deadline, no matter how large the send is; a peer draining
  # below it does. This is the same approach as Apache's mod_reqtimeout `MinRate`.
  #
  # All times are in ms of `:erlang.monotonic_time(:millisecond)`
  @spec extend_send_deadline(integer(), non_neg_integer(), integer(), pos_integer()) :: integer()
  def extend_send_deadline(deadline, bytes_sent, now, timeout) do
    credit = div(bytes_sent * 1000, @min_send_rate)
    Enum.min([deadline + credit, now + timeout])
  end
end
