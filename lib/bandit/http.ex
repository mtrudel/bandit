defmodule Bandit.HTTP do
  @moduledoc false
  # Implements functions shared by different HTTP versions

  @doc """
  Checks if a header tuple list already contains a date header
  """
  def has_date_header?([]), do: false
  def has_date_header?([{"date", _} | _rest]), do: true
  def has_date_header?([_ | rest]), do: has_date_header?(rest)
end
