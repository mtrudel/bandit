defmodule Bandit.Clock do
  @moduledoc false
  use Task

  def start_link(_opts) do
    Task.start_link(__MODULE__, :init, [])
  end

  def init() do
    __MODULE__ = :ets.new(__MODULE__, [:set, :protected, :named_table, {:read_concurrency, true}])

    run()
  end

  @doc """
  Returns the current timestamp according to RFC9110 5.6.7

  If the timestamp doesn't exist in the ETS table or the table doesn't exist
  the timestamp is newly created for every request
  """

  def date_header do
    date =
      try do
        :ets.lookup_element(__MODULE__, :date_header, 2)
      rescue
        ArgumentError ->
          get_date_header()
      end

    {"date", date}
  end

  def run do
    update_header()
    Process.sleep(1_000)
    run()
  end

  defp get_date_header, do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %X GMT")
  defp update_header, do: :ets.insert(__MODULE__, {:date_header, get_date_header()})
end
