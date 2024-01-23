defmodule Bandit.HTTP2.StreamCollection do
  @moduledoc false
  # Represents a map from stream id to pid with some useful properties:
  # * Accessible by stream id
  # * Deletable by pid
  # * Tracks streams not yet created & already closed
  # * Tracks the number of streams created

  require Integer

  defstruct last_stream_id: 0,
            stream_count: 0,
            id_to_pid: %{},
            pid_to_id: %{}

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "A map from stream id to pid"
  @type t :: %__MODULE__{
          last_stream_id: stream_id(),
          stream_count: non_neg_integer(),
          id_to_pid: %{stream_id() => pid()},
          pid_to_id: %{stream_id() => pid()}
        }

  @spec get_pids(t()) :: [pid()]
  def get_pids(collection), do: Map.values(collection.id_to_pid)

  @spec get_pid(t(), stream_id()) :: pid() | :new | :closed | :invalid
  def get_pid(_collection, stream_id) when Integer.is_even(stream_id), do: :invalid
  def get_pid(collection, stream_id) when stream_id > collection.last_stream_id, do: :new

  def get_pid(collection, stream_id) do
    case Map.get(collection.id_to_pid, stream_id) do
      pid when is_pid(pid) -> pid
      nil -> :closed
    end
  end

  @spec insert(t(), stream_id(), pid()) :: t()
  def insert(collection, stream_id, pid) do
    %__MODULE__{
      last_stream_id: stream_id,
      stream_count: collection.stream_count + 1,
      id_to_pid: Map.put(collection.id_to_pid, stream_id, pid),
      pid_to_id: Map.put(collection.pid_to_id, pid, stream_id)
    }
  end

  # Dialyzer insists on the atom() here even though it doesn't make sense
  @spec delete(t(), pid()) :: t() | atom()
  def delete(collection, pid) do
    case Map.pop(collection.pid_to_id, pid) do
      {nil, _} ->
        collection

      {stream_id, new_pid_to_id} ->
        %{
          collection
          | id_to_pid: Map.delete(collection.id_to_pid, stream_id),
            pid_to_id: new_pid_to_id
        }
    end
  end

  @spec stream_count(t()) :: non_neg_integer()
  def stream_count(collection), do: collection.stream_count

  @spec last_stream_id(t()) :: non_neg_integer()
  def last_stream_id(collection), do: collection.last_stream_id
end
