defmodule TelemetryHelpers do
  @moduledoc false

  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception],
    [:bandit, :websocket, :start],
    [:bandit, :websocket, :stop]
  ]

  def attach_all_events(plug_or_websock) do
    ref = make_ref()

    _ =
      :telemetry.attach_many(ref, @events, &__MODULE__.handle_event/4, {self(), plug_or_websock})

    fn -> :telemetry.detach(ref) end
  end

  def handle_event(event, measurements, %{plug: {plug, _}} = metadata, {pid, plug}),
    do: send(pid, {:telemetry, event, measurements, metadata})

  def handle_event(event, measurements, %{websock: websock} = metadata, {pid, websock}),
    do: send(pid, {:telemetry, event, measurements, metadata})

  def handle_event(_event, _measurements, _metadata, {_pid, _plug_or_websock}), do: :ok
end
