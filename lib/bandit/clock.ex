defmodule Bandit.Clock do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    __MODULE__ = :ets.new(__MODULE__, [:set, :protected, :named_table, {:read_concurrency, true}])
    update_header()
    timer_ref = Process.send_after(self(), :update, 1_000)
    {:ok, %{timer_ref: timer_ref}}
  end

  @doc """
  Returns the current timestamp according to RFC9110 5.6.7

  If the timestamp doesn't exist in the ETS table or the table doesn't exist
  the timestamp is newly created for every request
  """

  # def date_header do
  #   date =
  #     try do
  #       :ets.lookup_element(__MODULE__, :date_header, 2)
  #     rescue
  #       ArgumentError ->
  #         get_date_header()
  #     end

  #   {"date", date}
  # end

  def date_header do
    date = :ets.lookup_element(__MODULE__, :date_header, 2)

    {"date", date}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :stopped, state}
  end

  def handle_call(_req, _from, state) do
    {:reply, :ignored, state}
  end

  @impl GenServer
  def handle_info(:update, %{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    update_header()
    timer_ref = Process.send_after(self(), :update, 1_000)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp get_date_header, do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %X GMT")
  defp update_header, do: :ets.insert(__MODULE__, {:date_header, get_date_header()})
end
