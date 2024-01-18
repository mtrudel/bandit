defmodule Bandit.HTTP2.Stream do
  @moduledoc false
  # Carries out state management transitions per RFC9113§5.1. Anything having to do
  # with the internal state of a stream is handled in this module. Note that sending
  # of frames on behalf of a stream is a bit of a split responsibility: the stream
  # itself may update state depending on the value of the end_stream flag (this is
  # a stream concern and thus handled here), but the sending of the data over the
  # wire is a connection concern as it must be serialized properly & is subject to
  # flow control at a connection level

  require Logger

  alias Bandit.HTTP2.{Connection, Errors, StreamProcess}

  defstruct stream_id: nil,
            state: nil,
            pid: nil

  defmodule StreamError,
    do: defexception([:message, :method, :request_target, :status, :error_code])

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
          pid: pid() | nil
        }

  @spec recv_headers(
          t(),
          Bandit.TransportInfo.t(),
          ThousandIsland.Telemetry.t(),
          non_neg_integer(),
          Plug.Conn.headers(),
          boolean,
          Bandit.Pipeline.plug_def(),
          keyword()
        ) :: {:ok, t()} | {:error, Connection.error()} | {:error, error()}
  def recv_headers(
        %__MODULE__{state: state} = stream,
        _transport_info,
        _connection_span,
        _initial_send_window_size,
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
        initial_send_window_size,
        headers,
        _end_stream,
        plug,
        opts
      ) do
    case StreamProcess.start_link(
           self(),
           stream.stream_id,
           initial_send_window_size,
           transport_info,
           headers,
           plug,
           connection_span,
           opts
         ) do
      {:ok, pid} -> {:ok, %{stream | state: :open, pid: pid}}
      :ignore -> {:error, "Unable to start stream process"}
      other -> other
    end
  end

  def recv_headers(
        %__MODULE__{},
        _transport_info,
        _connection_span,
        _initial_send_window_size,
        _headers,
        _end_stream,
        _plug,
        _opts
      ) do
    {:error, {:connection, Errors.protocol_error(), "Received HEADERS in unexpected state"}}
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

  @spec recv_data(t(), binary()) :: {:ok, t()} | {:error, Connection.error()}
  def recv_data(%__MODULE__{state: state} = stream, data) when state in [:open, :local_closed] do
    StreamProcess.recv_data(stream.pid, data)
    {:ok, stream}
  end

  def recv_data(%__MODULE__{} = stream, _data) do
    {:error, {:connection, Errors.protocol_error(), "Received DATA when in #{stream.state}"}}
  end

  @spec recv_send_window_update(t(), non_neg_integer()) ::
          {:ok, t()} | {:error, Connection.error()} | {:error, error()}
  def recv_send_window_update(%__MODULE__{state: :idle}, _increment) do
    {:error, {:connection, Errors.protocol_error(), "Received WINDOW_UPDATE when in idle"}}
  end

  def recv_send_window_update(%__MODULE__{} = stream, increment) do
    if is_pid(stream.pid), do: StreamProcess.recv_send_window_update(stream.pid, increment)
    {:ok, stream}
  end

  @spec recv_rst_stream(t(), Errors.error_code()) ::
          {:ok, t()} | {:error, Connection.error()}
  def recv_rst_stream(%__MODULE__{state: :idle}, _error_code) do
    {:error, {:connection, Errors.protocol_error(), "Received RST_STREAM when in idle"}}
  end

  def recv_rst_stream(%__MODULE__{} = stream, error_code) do
    if is_pid(stream.pid), do: StreamProcess.recv_rst_stream(stream.pid, error_code)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  @spec recv_end_of_stream(t(), boolean()) ::
          {:ok, t()} | {:error, Connection.error()}
  def recv_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    StreamProcess.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :remote_closed}}
  end

  def recv_end_of_stream(%__MODULE__{state: :local_closed} = stream, true) do
    StreamProcess.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def recv_end_of_stream(%__MODULE__{}, true) do
    {:error, {:connection, Errors.protocol_error(), "Received unexpected end_stream"}}
  end

  def recv_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  @spec send_headers(t()) :: {:ok, t()} | {:error, :invalid_state}
  def send_headers(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_headers(%__MODULE__{}) do
    {:error, :invalid_state}
  end

  @spec send_data(t()) :: {:ok, t()} | {:error, :invalid_state}
  def send_data(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_data(%__MODULE__{}) do
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

  @spec stream_terminated(t(), term()) :: {:ok, t()}
  def stream_terminated(%__MODULE__{} = stream, _reason) do
    {:ok, %{stream | state: :closed, pid: nil}}
  end
end
