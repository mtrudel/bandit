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

  defstruct stream_id: nil,
            state: nil,
            pid: nil,
            recv_window_size: nil,
            send_window_size: nil,
            pending_content_length: nil

  require Integer
  require Logger

  alias Bandit.HTTP2.{Errors, FlowControl, StreamTask}

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "An HTTP/2 stream state"
  @type state :: :reserved_local | :idle | :open | :local_closed | :remote_closed | :closed

  @typedoc "A single HTTP/2 stream"
  @type t :: %__MODULE__{stream_id: stream_id(), state: state(), pid: pid() | nil}

  def recv_headers(%__MODULE__{state: state} = stream, trailers, true, _peer, _plug)
      when state in [:open, :local_closed] do
    with :ok <- no_pseudo_headers(trailers, stream.stream_id) do
      # These are actually trailers, which Plug doesn't support. Log and ignore
      Logger.warn("Ignoring trailers on stream #{stream.stream_id}: #{inspect(trailers)}")

      {:ok, stream}
    end
  end

  def recv_headers(%__MODULE__{state: :idle} = stream, headers, _end_stream, peer, plug) do
    with :ok <- stream_id_is_valid_client(stream.stream_id),
         :ok <- headers_all_lowercase(headers, stream.stream_id),
         :ok <- pseudo_headers_all_request(headers, stream.stream_id),
         :ok <- pseudo_headers_first(headers, stream.stream_id),
         :ok <- no_connection_headers(headers, stream.stream_id),
         :ok <- valid_te_header(headers, stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":scheme", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":method", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":path", stream.stream_id),
         :ok <- non_empty_path(headers, stream.stream_id),
         expected_content_length <- expected_content_length(headers) do
      {:ok, pid} = StreamTask.start_link(self(), stream.stream_id, headers, peer, plug)
      {:ok, %{stream | state: :open, pid: pid, pending_content_length: expected_content_length}}
    end
  end

  def recv_headers(%__MODULE__{}, _headers, _end_stream, _peer, _plug) do
    {:error, {:connection, Errors.protocol_error(), "Received HEADERS in unexpected state"}}
  end

  def send_push_headers(%__MODULE__{state: :idle} = stream, headers) do
    with :ok <- stream_id_is_valid_server(stream.stream_id),
         :ok <- headers_all_lowercase(headers, stream.stream_id),
         :ok <- pseudo_headers_all_request(headers, stream.stream_id),
         :ok <- pseudo_headers_first(headers, stream.stream_id),
         :ok <- no_connection_headers(headers, stream.stream_id),
         :ok <- valid_te_header(headers, stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":scheme", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":method", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":path", stream.stream_id),
         :ok <- non_empty_path(headers, stream.stream_id) do
      {:ok, %{stream | state: :reserved_local}}
    end
  end

  def start_push(%__MODULE__{state: :reserved_local} = stream, headers, peer, plug) do
    {:ok, pid} = StreamTask.start_link(self(), stream.stream_id, headers, peer, plug)
    {:ok, %{stream | state: :remote_closed, pid: pid}}
  end

  # RFC7540§5.1.1 - client initiated streams must be odd
  defp stream_id_is_valid_client(stream_id) do
    if Integer.is_odd(stream_id) do
      :ok
    else
      {:error, {:connection, Errors.protocol_error(), "Received HEADERS with even stream_id"}}
    end
  end

  # RFC7540§5.1.1 - server initiated streams must be even
  defp stream_id_is_valid_server(stream_id) do
    if Integer.is_even(stream_id) do
      :ok
    else
      {:error, {:connection, Errors.protocol_error(), "Sending HEADERS with odd stream_id"}}
    end
  end

  # RFC7540§8.1.2 - all headers name fields must be lowercsae
  defp headers_all_lowercase(headers, stream_id) do
    headers
    |> Enum.all?(fn {key, _value} -> String.downcase(key) == key end)
    |> if do
      :ok
    else
      {:error, {:stream, stream_id, Errors.protocol_error(), "Received uppercase header"}}
    end
  end

  # RFC7540§8.1.2.1 - only request pseudo headers may appear
  defp pseudo_headers_all_request(headers, stream_id) do
    headers
    |> Enum.all?(fn
      {":" <> key, _value} -> key in ~w[method scheme authority path]
      {_key, _value} -> true
    end)
    |> if do
      :ok
    else
      {:error, {:stream, stream_id, Errors.protocol_error(), "Received invalid pseudo header"}}
    end
  end

  # RFC7540§8.1.2.1 - pseudo headers must appear first
  defp no_pseudo_headers(headers, stream_id) do
    headers
    |> Enum.any?(fn {key, _value} -> String.starts_with?(key, ":") end)
    |> if do
      {:error,
       {:stream, stream_id, Errors.protocol_error(), "Received trailers with pseudo headers"}}
    else
      :ok
    end
  end

  # RFC7540§8.1.2.2 - pseudo headers must appear first
  defp pseudo_headers_first(headers, stream_id) do
    headers
    |> Enum.drop_while(fn {key, _value} -> String.starts_with?(key, ":") end)
    |> Enum.any?(fn {key, _value} -> String.starts_with?(key, ":") end)
    |> if do
      {:error,
       {:stream, stream_id, Errors.protocol_error(), "Received pseudo headers after regular one"}}
    else
      :ok
    end
  end

  # RFC7540§8.1.2.2 - no hop-by-hop headers from RFC2616§13.5.1
  # Note that we do not filter out the TE header here, since it is allowed in
  # specific cases by RFC7540§8.1.2.2. We check those cases in a separate filter
  defp no_connection_headers(headers, stream_id) do
    headers
    |> Enum.any?(fn {key, _value} ->
      key in ~w[connection keep-alive proxy-authenticate proxy-authorization trailers transfer-encoding upgrade]
    end)
    |> if do
      {:error,
       {:stream, stream_id, Errors.protocol_error(), "Received connection-specific header"}}
    else
      :ok
    end
  end

  # RFC7540§8.1.2.2 - TE header may be present if it contains exactly 'trailers'
  defp valid_te_header(headers, stream_id) do
    case List.keyfind(headers, "te", 0) do
      nil ->
        :ok

      {_, "trailers"} ->
        :ok

      _ ->
        {:error, {:stream, stream_id, Errors.protocol_error(), "Received invalid TE header"}}
    end
  end

  # RFC7540§8.1.2.3 - method, scheme, path pseudo headers must appear exactly once
  defp exactly_one_instance_of(headers, header, stream_id) do
    headers
    |> Enum.count(fn {key, _value} -> key == header end)
    |> case do
      1 ->
        :ok

      _ ->
        {:error, {:stream, stream_id, Errors.protocol_error(), "Expected 1 #{header} headers"}}
    end
  end

  # RFC7540§8.1.2.3 :path must not be empty
  defp non_empty_path(headers, stream_id) do
    case List.keyfind(headers, ":path", 0) do
      {_, ""} ->
        {:error, {:stream, stream_id, Errors.protocol_error(), "Received empty :path"}}

      _ ->
        :ok
    end
  end

  defp expected_content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      nil -> nil
      {_, content_length} -> String.to_integer(content_length)
    end
  end

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

  def recv_rst_stream(%__MODULE__{state: :idle}, _error_code) do
    {:error, {:connection, Errors.protocol_error(), "Received RST_STREAM when in idle"}}
  end

  def recv_rst_stream(%__MODULE__{} = stream, error_code) do
    if is_pid(stream.pid), do: StreamTask.recv_rst_stream(stream.pid, error_code)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

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

  def owner?(%__MODULE__{pid: pid}, pid), do: :ok
  def owner?(%__MODULE__{}, _pid), do: {:error, :not_owner}

  def get_send_window_size(%__MODULE__{} = stream), do: stream.send_window_size

  def send_headers(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_headers(%__MODULE__{}) do
    {:error, :invalid_state}
  end

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

  def terminate_stream(%__MODULE__{pid: pid}, reason) when is_pid(pid) do
    # Just kill the process; we will receive a call to stream_terminated once the process actually
    # dies, at which point we will transition the struct to the expected final state
    Process.exit(pid, reason)
  end

  def terminate_stream(%__MODULE__{}, _reason) do
    :ok
  end

  def stream_terminated(%__MODULE__{state: :closed} = stream, :normal) do
    {:ok, %{stream | state: :closed, pid: nil}, nil}
  end

  def stream_terminated(%__MODULE__{} = stream, {:bandit, reason}) do
    Logger.warn("Stream #{stream.stream_id} was killed by bandit (#{reason})")

    {:ok, %{stream | state: :closed, pid: nil}, nil}
  end

  def stream_terminated(%__MODULE__{} = stream, :normal) do
    Logger.warn("Stream #{stream.stream_id} completed in unexpected state #{stream.state}")

    {:ok, %{stream | state: :closed, pid: nil}, Errors.no_error()}
  end

  def stream_terminated(%__MODULE__{} = stream, reason) do
    Logger.error("Task for stream #{stream.stream_id} crashed with #{inspect(reason)}")

    {:ok, %{stream | state: :closed, pid: nil}, Errors.internal_error()}
  end
end
