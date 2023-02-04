defmodule Bandit.Logger do
  @moduledoc """
  Logging conveniences for Bandit servers

  Allows dynamically adding and altering the log level used to trace connections
  within a Bandit server via the use of telemetry hooks. Should you wish
  to do your own logging or tracking of these events, a complete list of the
  telemetry events emitted by Bandit is described in the module documentation
  for `Bandit.Telemetry`.

  The logging included in this module is concerned specifically with protocol level events.
  Should you wish to log lower level transport concens, there are similar functions to these in
  the `ThousandIsland.Logger` module. Corresponding telemetry events are described in the
  module documentation for `ThousandIsland.Telemetry`.
  """

  require Logger

  @typedoc "Supported log levels"
  @type log_level :: :error | :info | :debug | :trace

  @doc """
  Start logging Bandit at the specified log level. Valid values for log
  level are `:error`, `:info`, `:debug`, and `:trace`. Enabling a given log
  level implicitly enables all higher log levels as well.
  """
  @spec attach_logger(log_level()) :: :ok | {:error, :already_exists}
  def attach_logger(:error) do

    :telemetry.attach_many("#{__MODULE__}.error", events, &__MODULE__.log_error/4, nil)
  end

  def attach_logger(:info) do
    attach_logger(:error)


    :telemetry.attach_many("#{__MODULE__}.info", events, &__MODULE__.log_info/4, nil)
  end

  def attach_logger(:debug) do
    attach_logger(:info)


    :telemetry.attach_many("#{__MODULE__}.debug", events, &__MODULE__.log_debug/4, nil)
  end

  def attach_logger(:trace) do
    attach_logger(:debug)


    :telemetry.attach_many("#{__MODULE__}.trace", events, &__MODULE__.log_trace/4, nil)
  end

  @doc """
  Stop logging Thousand Island at the specified log level. Disabling a given log
  level implicitly disables all lower log levels as well.
  """
  @spec detach_logger(log_level()) :: :ok | {:error, :not_found}
  def detach_logger(:error) do
    detach_logger(:info)
    :telemetry.detach("#{__MODULE__}.error")
  end

  def detach_logger(:info) do
    detach_logger(:debug)
    :telemetry.detach("#{__MODULE__}.info")
  end

  def detach_logger(:debug) do
    detach_logger(:trace)
    :telemetry.detach("#{__MODULE__}.debug")
  end

  def detach_logger(:trace) do
    :telemetry.detach("#{__MODULE__}.trace")
  end

  @doc false
  def log_error(event, measurements, metadata, _config) do
    Logger.error(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  def log_info(event, measurements, metadata, _config) do
    Logger.info(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  def log_debug(event, measurements, metadata, _config) do
    Logger.debug(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  def log_trace(event, measurements, metadata, _config) do
    Logger.debug(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end
end
