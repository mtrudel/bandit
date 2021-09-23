defmodule Bandit.DelegatingHandler do
  @moduledoc """
  Delegates all inplementation of the ThousandIsland.Handler behaviour
  to an implementation specified in state. Allows for clean separation
  between protocol implementations & friction free protocol selection &
  upgrades.
  """

  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{handler_module: handler_module} = state) do
    handler_module.handle_connection(socket, state)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{handler_module: handler_module} = state) do
    handler_module.handle_data(data, socket, state)
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

  @impl GenServer
  def terminate(reason, %{handler_module: handler_module} = state) do
    handler_module.terminate(reason, state)
  end
end
