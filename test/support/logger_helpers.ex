defmodule LoggerHelpers do
  @moduledoc false

  # Sends a test the log events of a plug, a WebSock or a process, each as a `{:log, log_event}`
  # message.
  #
  # One :logger handler serves the whole run. It is added from test_helper.exs before any test
  # starts, and a Registry records which test wants which events. Tests used to add a handler
  # each, but :logger can lose a handler which is added while another one is being removed: the
  # removal writes back the list of handlers as it was when the removal was requested. ExUnit
  # removes a handler each time log capture starts or stops, so now and then a test lost its
  # handler and never saw the log event it was waiting for

  def install do
    case Registry.start_link(keys: :duplicate, name: __MODULE__) do
      {:ok, _pid} -> :logger.add_handler(__MODULE__, __MODULE__, %{})
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  def receive_all_log_events(plug_or_sock_or_pid) do
    {:ok, _pid} = Registry.register(__MODULE__, plug_or_sock_or_pid, nil)
    :ok
  end

  def log(%{meta: meta} = log_event, _config) do
    for key <- keys(meta) do
      Registry.dispatch(__MODULE__, key, fn tests ->
        for {pid, _value} <- tests, do: send(pid, {:log, log_event})
      end)
    end

    :ok
  end

  # :logger attaches the pid of the logging process to every log event
  defp keys(%{plug: {plug, _}} = meta), do: [plug, meta[:pid]]
  defp keys(%{websock: websock} = meta), do: [websock, meta[:pid]]
  defp keys(meta), do: [meta[:pid]]
end
