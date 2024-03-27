defmodule Bandit.Telemetry do
  @moduledoc """
  The following telemetry spans are emitted by bandit

  ## `[:bandit, :request, *]`

  Represents Bandit handling a specific client HTTP request

  This span is started by the following event:

  * `[:bandit, :request, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `connection_telemetry_span_context`: The span context of the Thousand Island `:connection`
        span which contains this request
      * `conn`: The `Plug.Conn` representing this connection. Not present in cases where `error`
        is also set and the nature of error is such that Bandit was unable to successfully build
        the conn

  This span is ended by the following event:

  * `[:bandit, :request, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units
      * `req_header_end_time`: The time that header reading completed, in `:native` units
      * `req_body_start_time`: The time that request body reading started, in `:native` units.
      * `req_body_end_time`: The time that request body reading completed, in `:native` units
      * `req_body_bytes`: The length of the request body, in octets
      * `resp_start_time`: The time that the response started, in `:native` units
      * `resp_end_time`: The time that the response completed, in `:native` units
      * `resp_body_bytes`: The length of the response body, in octets. If the response is
        compressed, this is the size of the compressed payload as sent on the wire
      * `resp_uncompressed_body_bytes`: The length of the original, uncompressed body. Only
        included for responses which are compressed
      * `resp_compression_method`: The method of compression, as sent in the `Content-Encoding`
        header of the response. Only included for responses which are compressed

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `connection_telemetry_span_context`: The span context of the Thousand Island `:connection`
        span which contains this request
      * `conn`: The `Plug.Conn` representing this connection. Not present in cases where `error`
        is also set and the nature of error is such that Bandit was unable to successfully build
        the conn
      * `error`: The error that caused the span to end, if it ended in error

  The following events may be emitted within this span:

  * `[:bandit, :request, :exception]`

      The request for this span ended unexpectedly

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `connection_telemetry_span_context`: The span context of the Thousand Island `:connection`
        span which contains this request
      * `conn`: The `Plug.Conn` representing this connection. Not present in cases where `error`
        is also set and the nature of error is such that Bandit was unable to successfully build
        the conn
      * `kind`: The kind of unexpected condition, typically `:exit`
      * `exception`: The exception which caused this unexpected termination
      * `stacktrace`: The stacktrace of the location which caused this unexpected termination

  ## `[:bandit, :websocket, *]`

  Represents Bandit handling a WebSocket connection

  This span is started by the following event:

  * `[:bandit, :websocket, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `compress`: Details about the compression configuration for this connection

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `connection_telemetry_span_context`: The span context of the Thousand Island `:connection`
        span which contains this request

  This span is ended by the following event:

  * `[:bandit, :websocket, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units
      * `recv_text_frame_count`: The number of text frames received
      * `recv_text_frame_bytes`: The total number of bytes received in the payload of text frames
      * `recv_binary_frame_count`: The number of binary frames received
      * `recv_binary_frame_bytes`: The total number of bytes received in the payload of binary frames
      * `recv_ping_frame_count`: The number of ping frames received
      * `recv_ping_frame_bytes`: The total number of bytes received in the payload of ping frames
      * `recv_pong_frame_count`: The number of pong frames received
      * `recv_pong_frame_bytes`: The total number of bytes received in the payload of pong frames
      * `recv_connection_close_frame_count`: The number of connection close frames received
      * `recv_connection_close_frame_bytes`: The total number of bytes received in the payload of connection close frames
      * `recv_continuation_frame_count`: The number of continuation frames received
      * `recv_continuation_frame_bytes`: The total number of bytes received in the payload of continuation frames
      * `send_text_frame_count`: The number of text frames sent
      * `send_text_frame_bytes`: The total number of bytes sent in the payload of text frames
      * `send_binary_frame_count`: The number of binary frames sent
      * `send_binary_frame_bytes`: The total number of bytes sent in the payload of binary frames
      * `send_ping_frame_count`: The number of ping frames sent
      * `send_ping_frame_bytes`: The total number of bytes sent in the payload of ping frames
      * `send_pong_frame_count`: The number of pong frames sent
      * `send_pong_frame_bytes`: The total number of bytes sent in the payload of pong frames
      * `send_connection_close_frame_count`: The number of connection close frames sent
      * `send_connection_close_frame_bytes`: The total number of bytes sent in the payload of connection close frames
      * `send_continuation_frame_count`: The number of continuation frames sent
      * `send_continuation_frame_bytes`: The total number of bytes sent in the payload of continuation frames

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `origin_telemetry_span_context`: The span context of the Bandit `:request` span from which
        this connection originated
      * `connection_telemetry_span_context`: The span context of the Thousand Island `:connection`
        span which contains this request
      * `error`: The error that caused the span to end, if it ended in error
  """

  defstruct span_name: nil, telemetry_span_context: nil, start_time: nil, start_metadata: nil

  @typep span_name :: atom()
  @opaque t :: %__MODULE__{
            span_name: span_name(),
            telemetry_span_context: reference(),
            start_time: integer(),
            start_metadata: :telemetry.event_metadata()
          }

  @app_name :bandit

  @doc false
  @spec start_span(span_name(), :telemetry.event_measurements(), :telemetry.event_metadata()) ::
          t()
  def start_span(span_name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
    telemetry_span_context = make_ref()
    metadata = Map.put(metadata, :telemetry_span_context, telemetry_span_context)
    event([span_name, :start], measurements, metadata)

    %__MODULE__{
      span_name: span_name,
      telemetry_span_context: telemetry_span_context,
      start_time: measurements[:monotonic_time],
      start_metadata: metadata
    }
  end

  @doc false
  @spec stop_span(t(), :telemetry.event_measurements(), :telemetry.event_metadata()) :: :ok
  def stop_span(span, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)

    measurements =
      Map.put(measurements, :duration, measurements[:monotonic_time] - span.start_time)

    metadata = Map.merge(span.start_metadata, metadata)

    untimed_span_event(span, :stop, measurements, metadata)
  end

  @spec span_exception(t(), Exception.kind(), Exception.t(), Exception.stacktrace()) :: :ok
  def span_exception(span, kind, exception, stacktrace) do
    metadata =
      Map.merge(span.start_metadata, %{
        kind: kind,
        exception: exception,
        stacktrace: stacktrace
      })

    span_event(span, :exception, %{}, metadata)
  end

  @doc false
  @spec span_event(t(), span_name(), :telemetry.event_measurements(), :telemetry.event_metadata()) ::
          :ok
  def span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
    untimed_span_event(span, name, measurements, metadata)
  end

  @doc false
  @spec untimed_span_event(
          t(),
          span_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata()
        ) :: :ok
  def untimed_span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    metadata = Map.put(metadata, :telemetry_span_context, span.telemetry_span_context)
    event([span.span_name, name], measurements, metadata)
  end

  @spec monotonic_time :: integer()
  defdelegate monotonic_time, to: System

  @spec event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata()
        ) :: :ok
  defp event(suffix, measurements, metadata) do
    :telemetry.execute([@app_name | suffix], measurements, metadata)
  end

  @doc false
  @spec telemetry_span_context(t()) :: reference()
  def telemetry_span_context(span) do
    span.telemetry_span_context
  end
end
