defmodule Bandit.Telemetry do
  @moduledoc """
  The following telemetry spans are emitted by bandit

  ## `[:bandit, :request, *]`

  Represents Bandit handling a specific client HTTP request

  This span is started by the following event:

  * `[:bandit, :request, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `span_id`: The ID of this span
      * `connection_span_id`: The span ID of the Thousand Island `:connection` span which contains this request

  This span is ended by the following event:

  * `[:bandit, :request, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units
      * `req_header_end_time`: The time that header reading completed, in `:native` units
      * `req_body_start_time`: The time that request body reading started, in `:native` units.
      * `req_body_end_time`: The time that request body reading completed, in `:native` units
      * `req_line_bytes`: The length of the request line, in octets. Includes all line breaks.
        Not included for HTTP/2 requests
      * `req_header_bytes`: The length of the request headers, in octets. Includes all line
        breaks. Not included for HTTP/2 requests
      * `req_body_bytes`: The length of the request body, in octets
      * `resp_status`: The HTTP status code of the reponse
      * `resp_start_time`: The time that the response started, in `:native` units
      * `resp_end_time`: The time that the response completed, in `:native` units. Not included
        for chunked responses
      * `resp_line_bytes`: The length of the reponse line, in octets. Includes all line breaks.
        Not included for HTTP/2 requests
      * `resp_header_bytes`: The length of the reponse headers, in octets. Includes all line
        breaks. Not included for HTTP/2 requests
      * `resp_body_bytes`: The length of the reponse body, in octets. Set to 0 for chunked responses

      This event contains the following metadata:

      * `span_id`: The ID of this span
      * `error`: The error that caused the span to end, if it ended in error
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
