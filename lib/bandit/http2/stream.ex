defmodule Bandit.HTTP2.Stream do
  @moduledoc false
  # Carries out state management transitions per RFC9113§5.1. Anything having to do
  # with the internal state of a stream is handled in this module. Note that sending
  # of frames on behalf of a stream is a bit of a split responsibility: the stream
  # itself may update state depending on the value of the end_stream flag (this is
  # a stream concern and thus handled here), but the sending of the data over the
  # wire is a connection concern as it must be serialized properly & is subject to
  # flow control at a connection level

  require Integer
  require Logger

  alias Bandit.HTTP2.{Connection, Errors, FlowControl, StreamTask}

  defstruct stream_id: nil,
            state: nil,
            pid: nil,
            recv_window_size: nil,
            send_window_size: nil,
            pending_content_length: nil,
            span: nil

  defmodule StreamError, do: defexception([:message, :method, :request_target, :status])

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "An HTTP/2 stream state"
  @type state :: :reserved_local | :idle | :open | :local_closed | :remote_closed | :closed

  @typedoc "A description of a stream error"
  @type error :: {:stream, stream_id(), Errors.error_code(), String.t()}

  @typedoc "A single HTTP/2 stream"
  @type t :: %__MODULE__{
          stream_id: stream_id(),
          state: state(),
          pid: pid() | nil,
          recv_window_size: non_neg_integer(),
          send_window_size: non_neg_integer(),
          pending_content_length: non_neg_integer() | nil,
          span: Bandit.Telemetry.t()
        }

  @spec recv_headers(
          t(),
          Bandit.TransportInfo.t(),
          ThousandIsland.Telemetry.t(),
          Plug.Conn.headers(),
          boolean,
          Bandit.Pipeline.plug_def(),
          keyword()
        ) :: {:ok, t()} | {:error, Connection.error()} | {:error, error()}
  def recv_headers(
        %__MODULE__{state: state} = stream,
        _transport_info,
        _connection_span,
        trailers,
        true,
        _plug,
        _opts
      )
      when state in [:open, :local_closed] do
    with :ok <- no_pseudo_headers(trailers, stream.stream_id) do
      # These are actually trailers, which Plug doesn't support. Log and ignore
      Logger.warning("Ignoring trailers on stream #{stream.stream_id}: #{inspect(trailers)}")

      {:ok, stream}
    end
  end

  def recv_headers(
        %__MODULE__{state: :idle} = stream,
        transport_info,
        connection_span,
        headers,
        _end_stream,
        plug,
        opts
      ) do
    with :ok <- stream_id_is_valid_client(stream.stream_id),
         span <- start_span(connection_span, stream.stream_id),
         {:ok, content_length} <- get_content_length(headers, stream.stream_id),
         content_encoding <- negotiate_content_encoding(headers, opts),
         req <-
           Bandit.HTTP2.Adapter.init(
             self(),
             transport_info,
             stream.stream_id,
             content_encoding,
             opts
           ),
         {:ok, pid} <- StreamTask.start_link(req, transport_info, headers, plug, span) do
      {:ok,
       %{stream | state: :open, pid: pid, pending_content_length: content_length, span: span}}
    end
  end

  def recv_headers(
        %__MODULE__{},
        _transport_info,
        _connection_span,
        _headers,
        _end_stream,
        _plug,
        _opts
      ) do
    {:error, {:connection, Errors.protocol_error(), "Received HEADERS in unexpected state"}}
  end

  # RFC9113§5.1.1 - client initiated streams must be odd
  defp stream_id_is_valid_client(stream_id) do
    if Integer.is_odd(stream_id) do
      :ok
    else
      {:error, {:connection, Errors.protocol_error(), "Received HEADERS with even stream_id"}}
    end
  end

  defp start_span(connection_span, stream_id) do
    Bandit.Telemetry.start_span(:request, %{}, %{
      connection_telemetry_span_context: connection_span.telemetry_span_context,
      stream_id: stream_id
    })
  end

  # RFC9113§8.1.1 - content length must be valid
  defp get_content_length(headers, stream_id) do
    case Bandit.Headers.get_content_length(headers) do
      {:ok, content_length} -> {:ok, content_length}
      {:error, reason} -> {:error, {:stream, stream_id, Errors.protocol_error(), reason}}
    end
  end

  defp negotiate_content_encoding(headers, opts) do
    Bandit.Compression.negotiate_content_encoding(
      Bandit.Headers.get_header(headers, "accept-encoding"),
      Keyword.get(opts, :compress, true)
    )
  end

  # RFC9113§8.1 - no pseudo headers
  defp no_pseudo_headers(headers, stream_id) do
    if Enum.any?(headers, fn {key, _value} -> String.starts_with?(key, ":") end) do
      {:error,
       {:stream, stream_id, Errors.protocol_error(), "Received trailers with pseudo headers"}}
    else
      :ok
    end
  end

  @spec recv_data(t(), binary()) :: {:ok, t(), non_neg_integer()} | {:error, Connection.error()}
  def recv_data(%__MODULE__{state: state} = stream, data) when state in [:open, :local_closed] do
    StreamTask.recv_data(stream.pid, data)

    {new_window, increment} =
      FlowControl.compute_recv_window(stream.recv_window_size, byte_size(data))

    pending_content_length =
      case stream.pending_content_length do
        nil -> nil
        pending_content_length -> pending_content_length - byte_size(data)
      end

    {:ok,
     %{stream | recv_window_size: new_window, pending_content_length: pending_content_length},
     increment}
  end

  def recv_data(%__MODULE__{} = stream, _data) do
    {:error, {:connection, Errors.protocol_error(), "Received DATA when in #{stream.state}"}}
  end

  @spec recv_window_update(t(), non_neg_integer()) ::
          {:ok, t()} | {:error, Connection.error()} | {:error, error()}
  def recv_window_update(%__MODULE__{state: :idle}, _increment) do
    {:error, {:connection, Errors.protocol_error(), "Received WINDOW_UPDATE when in idle"}}
  end

  def recv_window_update(%__MODULE__{} = stream, increment) do
    case FlowControl.update_send_window(stream.send_window_size, increment) do
      {:ok, new_window} ->
        {:ok, %{stream | send_window_size: new_window}}

      {:error, error} ->
        {:error, {:stream, stream.stream_id, Errors.flow_control_error(), error}}
    end
  end

  @spec recv_rst_stream(t(), Errors.error_code()) ::
          {:ok, t()} | {:error, Connection.error()}
  def recv_rst_stream(%__MODULE__{state: :idle}, _error_code) do
    {:error, {:connection, Errors.protocol_error(), "Received RST_STREAM when in idle"}}
  end

  def recv_rst_stream(%__MODULE__{} = stream, error_code) do
    if is_pid(stream.pid), do: StreamTask.recv_rst_stream(stream.pid, error_code)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  @spec recv_end_of_stream(t(), boolean()) ::
          {:ok, t()} | {:error, Connection.error()}
  def recv_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    with :ok <- verify_content_length(stream) do
      StreamTask.recv_end_of_stream(stream.pid)
      {:ok, %{stream | state: :remote_closed}}
    end
  end

  def recv_end_of_stream(%__MODULE__{state: :local_closed} = stream, true) do
    with :ok <- verify_content_length(stream) do
      StreamTask.recv_end_of_stream(stream.pid)
      {:ok, %{stream | state: :closed, pid: nil}}
    end
  end

  def recv_end_of_stream(%__MODULE__{}, true) do
    {:error, {:connection, Errors.protocol_error(), "Received unexpected end_stream"}}
  end

  def recv_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  defp verify_content_length(%__MODULE__{pending_content_length: nil}), do: :ok
  defp verify_content_length(%__MODULE__{pending_content_length: 0}), do: :ok

  defp verify_content_length(%__MODULE__{} = stream) do
    {:error,
     {:stream, stream.stream_id, Errors.protocol_error(),
      "Received end of stream with #{stream.pending_content_length} byte(s) pending"}}
  end

  @spec owner?(t(), pid()) :: :ok | {:error, :not_owner}
  def owner?(%__MODULE__{pid: pid}, pid), do: :ok
  def owner?(%__MODULE__{}, _pid), do: {:error, :not_owner}

  @spec get_send_window_size(t()) :: non_neg_integer()
  def get_send_window_size(%__MODULE__{} = stream), do: stream.send_window_size

  @spec send_headers(t()) :: {:ok, t()} | {:error, :invalid_state}
  def send_headers(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_headers(%__MODULE__{}) do
    {:error, :invalid_state}
  end

  @spec send_data(t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :insufficient_window_size} | {:error, :invalid_state}
  def send_data(%__MODULE__{state: state} = stream, 0) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_data(%__MODULE__{state: state} = stream, len) when state in [:open, :remote_closed] do
    if len <= stream.send_window_size do
      {:ok, %{stream | send_window_size: stream.send_window_size - len}}
    else
      {:error, :insufficient_window_size}
    end
  end

  def send_data(%__MODULE__{}, _len) do
    {:error, :invalid_state}
  end

  @spec send_end_of_stream(t(), boolean()) :: {:ok, t()} | {:error, :invalid_state}
  def send_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    {:ok, %{stream | state: :local_closed}}
  end

  def send_end_of_stream(%__MODULE__{state: :remote_closed} = stream, true) do
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def send_end_of_stream(%__MODULE__{}, true) do
    {:error, :invalid_state}
  end

  def send_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  @spec terminate_stream(t(), term()) :: :ok
  def terminate_stream(%__MODULE__{pid: pid}, reason) when is_pid(pid) do
    # Just kill the process; we will receive a call to stream_terminated once the process actually
    # dies, at which point we will transition the struct to the expected final state
    Process.exit(pid, reason)
    :ok
  end

  def terminate_stream(%__MODULE__{}, _reason) do
    :ok
  end

  @spec stream_terminated(t(), term()) :: {:ok, t(), Errors.error_code() | nil}
  def stream_terminated(%__MODULE__{state: :closed} = stream, :normal) do
    # In the normal case, stop telemetry is emitted by the stream process to keep the main
    # connection process unblocked. In error cases we send from here, however, since there are
    # many error cases which never involve the stream process at all
    {:ok, %{stream | state: :closed, pid: nil}, nil}
  end

  def stream_terminated(%__MODULE__{} = stream, {:bandit, reason}) do
    Bandit.Telemetry.stop_span(stream.span, %{}, %{error: reason})
    Logger.warning("Stream #{stream.stream_id} was killed by bandit (#{reason})")
    {:ok, %{stream | state: :closed, pid: nil}, nil}
  end

  def stream_terminated(%__MODULE__{} = stream, {%StreamError{} = error, _}) do
    Bandit.Telemetry.stop_span(stream.span, %{}, %{
      error: error.message,
      method: error.method,
      request_target: error.request_target,
      status: error.status
    })

    Logger.warning("Stream #{stream.stream_id} encountered a stream error (#{inspect(error)})")
    {:ok, %{stream | state: :closed, pid: nil}, Errors.protocol_error()}
  end

  def stream_terminated(%__MODULE__{} = stream, :normal) do
    Logger.warning("Stream #{stream.stream_id} completed in unexpected state #{stream.state}")
    {:ok, %{stream | state: :closed, pid: nil}, Errors.no_error()}
  end

  def stream_terminated(%__MODULE__{} = stream, reason) do
    case reason do
      {exception, stacktrace} ->
        Bandit.Telemetry.span_exception(stream.span, :exit, exception, stacktrace)

      _ ->
        :ok
    end

    Logger.error("Task for stream #{stream.stream_id} crashed with #{inspect(reason)}")

    {:ok, %{stream | state: :closed, pid: nil}, Errors.internal_error()}
  end
end
