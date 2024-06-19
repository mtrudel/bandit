defmodule Bandit.Clock do
  @moduledoc false
  # Task which updates an ETS table with the current pre-formatted HTTP header
  # timestamp once a second. This saves the individual request processes from
  # having to construct this themselves, since it is a surprisingly expensive
  # operation

  use Task, restart: :permanent

  require Logger

  @doc """
  Returns the current timestamp according to RFC9110§5.6.7.

  If the timestamp doesn't exist in the ETS table or the table doesn't exist
  the timestamp is newly created for every request
  """
  @spec date_header() :: {header :: binary(), date :: binary()}
  def date_header do
    date =
      try do
        :ets.lookup_element(__MODULE__, :date_header, 2)
      rescue
        ArgumentError ->
          Logger.warning("Header timestamp couldn't be fetched from ETS cache", domain: [:bandit])
          get_date_header()
      end

    {"date", date}
  end

  @spec start_link(any()) :: {:ok, pid()}
  def start_link(_opts) do
    Task.start_link(__MODULE__, :init, [])
  end

  @spec init :: no_return()
  def init do
    __MODULE__ = :ets.new(__MODULE__, [:set, :protected, :named_table, {:read_concurrency, true}])

    run()
  end

  @spec run() :: no_return()
  defp run do
    _ = update_header()
    Process.sleep(1_000)
    run()
  end

  @spec get_date_header() :: String.t()
  defp get_date_header, do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %X GMT")

  @spec update_header() :: true
  defp update_header, do: :ets.insert(__MODULE__, {:date_header, get_date_header()})
end
