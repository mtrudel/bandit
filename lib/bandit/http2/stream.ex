defmodule Bandit.HTTP2.Stream do
  @moduledoc """
  Carries out state management transitions per RFC7540§5.1. Anything having to do
  with the internal state of a stream is handled in this module. Note that sending
  of frames on behalf of a stream is a bit of a split responsibility: the stream
  itself may update state depending on the value of the end_stream flag (this is 
  a stream concern and thus handled here), but the sending of the data over the
  wire is a connection concern as it must be serialized properly & is subject to
  flow control at a connection level
  """

  defstruct stream_id: nil, state: nil, pid: nil

  require Integer

  alias Bandit.HTTP2.{Constants, StreamTask}

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "An HTTP/2 stream state"
  @type state :: :idle | :open | :local_closed | :remote_closed | :closed

  @typedoc "A single HTTP/2 stream"
  @type t :: %__MODULE__{stream_id: stream_id(), state: state(), pid: pid() | nil}

  def recv_headers(%__MODULE__{state: :idle} = stream, headers, peer, plug) do
    if Integer.is_odd(stream.stream_id) do
      {:ok, pid} = StreamTask.start_link(self(), stream.stream_id, peer, headers, plug)
      {:ok, %{stream | state: :open, pid: pid}}
    else
      {:error, {:connection, Constants.protocol_error(), "Received HEADERS with even stream_id"}}
    end
  end

  def recv_headers(%__MODULE__{}, _headers, _peer, _plug) do
    {:error, {:connection, Constants.protocol_error(), "Received HEADERS when not in idle"}}
  end

  def recv_data(%__MODULE__{state: state} = stream, data) when state in [:open, :local_closed] do
    StreamTask.recv_data(stream.pid, data)
    {:ok, stream}
  end

  def recv_data(%__MODULE__{} = stream, _data) do
    {:error, {:connection, Constants.protocol_error(), "Received DATA when in #{stream.state}"}}
  end

  def recv_rst_stream(%__MODULE__{state: :idle}, _error_code) do
    {:error, {:connection, Constants.protocol_error(), "Received RST_STREAM when in idle"}}
  end

  def recv_rst_stream(%__MODULE__{} = stream, error_code) do
    if is_pid(stream.pid), do: StreamTask.recv_rst_stream(stream.pid, error_code)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def recv_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    StreamTask.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :remote_closed}}
  end

  def recv_end_of_stream(%__MODULE__{state: :local_closed} = stream, true) do
    StreamTask.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def recv_end_of_stream(%__MODULE__{}, true) do
    {:error, {:connection, Constants.protocol_error(), "Received unexpected end_stream"}}
  end

  def recv_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  def owner?(%__MODULE__{pid: pid}, pid), do: :ok
  def owner?(%__MODULE__{}, _pid), do: {:error, :not_owner}

  def send_headers(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_headers(%__MODULE__{}) do
    {:error, :invalid_state}
  end

  def send_data(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_data(%__MODULE__{}) do
    {:error, :invalid_state}
  end

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

  def close(%__MODULE__{} = stream, _reason) do
    {:ok, %{stream | state: :closed, pid: nil}}
  end
end
