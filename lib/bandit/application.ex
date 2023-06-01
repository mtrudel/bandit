defmodule Bandit.Application do
  @moduledoc false

  use Application

  @impl Application
  @spec start(Application.start_type(), start_args :: term) ::
          {:ok, pid}
          | {:error, {:already_started, pid} | {:shutdown, term} | term}
  def start(_type, _args) do
    children = [Bandit.Clock]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
