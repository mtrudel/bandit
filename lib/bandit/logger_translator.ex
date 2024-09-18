defmodule Bandit.LoggerTranslator do
  def translate(_min_level, :error, :report, {:logger, %{reason: {:bad_return_value, value}}}) do
    stacktrace = []
    {
      :ok,
      Exception.format(:throw, value, stacktrace),
      crash_reason: {{:nocatch, value}, stacktrace}, domain: :bandit
    }
  end

  def translate(_min_level, :error, :report, {:logger, %{reason: {exception, stacktrace}}}) when is_exception(exception) do
    {
      :ok,
      Exception.format(:error, exception, stacktrace),
      crash_reason: {exception, stacktrace}, domain: :bandit
    }
  end

  def translate(_min_level, :error, :report, {:logger, %{reason: {reason, stacktrace}}}) do
    {
      :ok,
      Exception.format(:exit, reason, stacktrace),
      crash_reason: {reason, stacktrace}, domain: :bandit
    }
  end

  def translate(_min_level, _level, _kind, _message) do
    :none
  end
end
