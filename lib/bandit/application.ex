defmodule Bandit.Application do
  @moduledoc false

  use Application

  @impl Application
  @spec start(Application.start_type(), start_args :: term) ::
          {:ok, pid}
          | {:error, {:already_started, pid} | {:shutdown, term} | term}
  def start(_type, _args) do
    if function_exported?(:proc_lib, :set_label, 1) do
      apply(:proc_lib, :set_label, ["Bandit.Application"])
    end

    children = [Bandit.Clock]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
