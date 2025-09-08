defmodule Bandit.Logger do
  @moduledoc false

  require Logger

  def maybe_log_protocol_error(error, stacktrace, opts, metadata) do
    logging_verbosity =
      case error do
        %Bandit.TransportError{error: :closed} ->
          Keyword.get(opts.http, :log_client_closures, false)

        _error ->
          Keyword.get(opts.http, :log_protocol_errors, :short)
      end

    case logging_verbosity do
      :short ->
        logger_metadata = logger_metadata_for(:error, error, stacktrace, metadata)
        Logger.error(Exception.format_banner(:error, error, stacktrace), logger_metadata)

      :verbose ->
        logger_metadata = logger_metadata_for(:error, error, stacktrace, metadata)
        Logger.error(Exception.format(:error, error, stacktrace), logger_metadata)

      false ->
        :ok
    end
  end

  def logger_metadata_for(kind, reason, stacktrace, metadata) do
    crash_reason = crash_reason(kind, reason, stacktrace)

    case reason do
      %Bandit.HTTP2.Errors.StreamError{stream_id: stream_id} when is_integer(stream_id) ->
        [stream_id: stream_id, domain: [:bandit], crash_reason: crash_reason]
        |> Keyword.merge(metadata)

      _ ->
        [domain: [:bandit], crash_reason: crash_reason]
        |> Keyword.merge(metadata)
    end
  end

  defp crash_reason(:throw, reason, stacktrace), do: {{:nocatch, reason}, stacktrace}
  defp crash_reason(_, reason, stacktrace), do: {reason, stacktrace}
end
