defmodule Bandit.HTTP do
  @moduledoc false
  # Implements functions shared by different HTTP versions

  @doc """
  Checks if a header tuple list already contains a date header
  """
  def has_date_header?(headers) do
    Enum.any?(headers, fn {header, _value} ->
      String.downcase(header) == "date"
    end)
  end
end
