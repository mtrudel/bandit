defmodule Bandit.DelegatingHandler do
  @moduledoc false
  # Delegates all implementation of the ThousandIsland.Handler behaviour
  # to an implementation specified in state. Allows for clean separation
  # between protocol implementations & friction free protocol selection &
  # upgrades.

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{handler_module: handler_module} = state) do
    handler_module.handle_connection(socket, state)
    |> handle_bandit_continuation(socket)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{handler_module: handler_module} = state) do
    handler_module.handle_data(data, socket, state)
    |> handle_bandit_continuation(socket)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, %{handler_module: handler_module} = state) do
    handler_module.handle_shutdown(socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_close(socket, %{handler_module: handler_module} = state) do
    handler_module.handle_close(socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_timeout(socket, %{handler_module: handler_module} = state) do
    handler_module.handle_timeout(socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_error(error, socket, %{handler_module: handler_module} = state) do
    handler_module.handle_error(error, socket, state)
  end

  @impl GenServer
  def handle_call(msg, from, {_socket, %{handler_module: handler_module}} = state) do
    handler_module.handle_call(msg, from, state)
  end

  @impl GenServer
  def handle_cast(msg, {_socket, %{handler_module: handler_module}} = state) do
    handler_module.handle_cast(msg, state)
  end

  @impl GenServer
  def handle_info(msg, {_socket, %{handler_module: handler_module}} = state) do
    handler_module.handle_info(msg, state)
  end

  defp handle_bandit_continuation(continuation, socket) do
    case continuation do
      {:switch, next_handler, state} ->
        handle_connection(socket, %{state | handler_module: next_handler})

      {:switch, next_handler, data, state} ->
        case handle_connection(socket, %{state | handler_module: next_handler}) do
          {:continue, state} ->
            handle_data(data, socket, state)

          {:continue, state, _timeout} ->
            handle_data(data, socket, state)

          other ->
            other
        end

      other ->
        other
    end
  end
end
