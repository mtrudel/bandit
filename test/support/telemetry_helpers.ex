defmodule TelemetryHelpers do
  @moduledoc false

  defmacro attach_all_events(plug_or_websock) do
    events = [
      [:bandit, :request, :start],
      [:bandit, :request, :stop],
      [:bandit, :request, :exception],
      [:bandit, :websocket, :start],
      [:bandit, :websocket, :stop]
    ]

    quote do
      ref = make_ref()

      :telemetry.attach_many(
        ref,
        unquote(events),
        &TelemetryHelpers.handle_event/4,
        {self(), unquote(plug_or_websock)}
      )

      on_exit(fn -> :telemetry.detach(ref) end)
    end
  end

  def handle_event(event, measurements, %{plug: {plug, _}} = metadata, {pid, plug}),
    do: send(pid, {:telemetry, event, measurements, metadata})

  def handle_event(event, measurements, %{websock: websock} = metadata, {pid, websock}),
    do: send(pid, {:telemetry, event, measurements, metadata})

  def handle_event(_event, _measurements, _metadata, {_pid, _plug_or_websock}), do: :ok
end
