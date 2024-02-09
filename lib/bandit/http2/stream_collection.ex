defmodule Bandit.HTTP2.StreamCollection do
  @moduledoc false
  # Represents a collection of stream IDs and what process IDs are running them. An instance of
  # this struct is contained within each `Bandit.HTTP2.Connection` struct and is responsible for
  # encapsulating the data about the streams which are currently active within the connection.
  #
  # This collection has a number of useful properties:
  #
  # * Process IDs are accessible by stream id
  # * Process IDs are deletable by themselves (ie: deletion is via PID)
  # * The collection is able to determine if a stream not currently contained in this collection
  #   represents a previously seen stream (in which case it is considered to be in a 'closed'
  #   state), or if it is a stream ID of a stream that has yet to be created

  require Integer

  defstruct last_stream_id: 0,
            stream_count: 0,
            id_to_pid: %{},
            pid_to_id: %{}

  @typedoc "A map from stream id to pid"
  @type t :: %__MODULE__{
          last_stream_id: Bandit.HTTP2.Stream.stream_id(),
          stream_count: non_neg_integer(),
          id_to_pid: %{Bandit.HTTP2.Stream.stream_id() => pid()},
          pid_to_id: %{pid() => Bandit.HTTP2.Stream.stream_id()}
        }

  @spec get_pids(t()) :: [pid()]
  def get_pids(collection), do: Map.values(collection.id_to_pid)

  @spec get_pid(t(), Bandit.HTTP2.Stream.stream_id()) :: pid() | :new | :closed | :invalid
  def get_pid(_collection, stream_id) when Integer.is_even(stream_id), do: :invalid
  def get_pid(collection, stream_id) when stream_id > collection.last_stream_id, do: :new

  def get_pid(collection, stream_id) do
    case Map.get(collection.id_to_pid, stream_id) do
      pid when is_pid(pid) -> pid
      nil -> :closed
    end
  end

  @spec insert(t(), Bandit.HTTP2.Stream.stream_id(), pid()) :: t()
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

  @spec last_stream_id(t()) :: Bandit.HTTP2.Stream.stream_id()
  def last_stream_id(collection), do: collection.last_stream_id
end
