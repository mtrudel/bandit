defmodule Bandit.LoggerTranslator do
  def translate(_min_level, :error, :report, {:logger, %{reason: {exception, stacktrace}}}) do
    {
      :ok,
      Exception.format(:error, exception, stacktrace),
      domain: :bandit
    }
  end

  def translate(_min_level, _level, _kind, _message) do
    :none
  end
end
