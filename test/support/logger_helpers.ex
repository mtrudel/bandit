defmodule LoggerHelpers do
  @moduledoc false

  def receive_all_log_events(plug_or_sock) do
    # Yes, this burns atoms but logger needs atoms for refs. See note below about at_exit
    ref = make_ref() |> inspect() |> String.to_atom()

    :logger.add_handler(ref, __MODULE__, %{config: %{pid: self(), plug: plug_or_sock}})

    # Ideally we'd have an at_exit hook that calls remove_handler but it seems to be racy inside
    # logger if we do so
  end

  def log(%{meta: %{plug: {plug, _}}} = log_event, %{config: %{pid: pid, plug: plug}}),
    do: send(pid, {:log, log_event})

  def log(%{meta: %{websock: websock}} = log_event, %{config: %{pid: pid, websock: websock}}),
    do: send(pid, {:log, log_event})

  def log(_log_event, _config), do: :ok
end
