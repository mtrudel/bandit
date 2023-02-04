defmodule Bandit.Telemetry do
  @moduledoc """
  """

  defstruct span_name: nil, span_id: nil, start_time: nil

  @opaque t :: %__MODULE__{
            span_name: atom(),
            span_id: String.t(),
            start_time: integer()
          }

  @app_name :bandit

  @doc false
  @spec start_span(atom(), map(), map()) :: t()
  def start_span(span_name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :time, &time/0)
    span_id = random_identifier()
    metadata = Map.put(metadata, :span_id, span_id)
    event([span_name, :start], measurements, metadata)
    %__MODULE__{span_name: span_name, span_id: span_id, start_time: measurements[:time]}
  end

  @doc false
  @spec start_child_span(t(), atom(), map(), map()) :: t()
  def start_child_span(parent_span, span_name, measurements \\ %{}, metadata \\ %{}) do
    metadata = Map.put(metadata, :parent_id, parent_span.span_id)
    start_span(span_name, measurements, metadata)
  end

  @doc false
  @spec stop_span(t(), map(), map()) :: :ok
  def stop_span(span, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :time, &time/0)
    measurements = Map.put(measurements, :duration, measurements[:time] - span.start_time)
    untimed_span_event(span, :stop, measurements, metadata)
  end

  @doc false
  @spec span_event(t(), atom(), map(), map()) :: :ok
  def span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :time, &time/0)
    untimed_span_event(span, name, measurements, metadata)
  end

  @doc false
  @spec untimed_span_event(t(), atom(), map(), map()) :: :ok
  def untimed_span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    metadata = Map.put(metadata, :span_id, span.span_id)
    event([span.span_name, name], measurements, metadata)
  end

  defdelegate time, to: System, as: :monotonic_time

  defp event(suffix, measurements, metadata) do
    :telemetry.execute([@app_name | suffix], measurements, metadata)
  end

  # XXX Drop this once we drop support for OTP 23
  @compile {:inline, random_identifier: 0}
  if function_exported?(:rand, :bytes, 1) do
    defp random_identifier, do: Base.encode32(:rand.bytes(10), padding: false)
  else
    defp random_identifier, do: Base.encode32(:crypto.strong_rand_bytes(10), padding: false)
  end
end
