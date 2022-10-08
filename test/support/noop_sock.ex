defmodule NoopSock do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      def init(arg), do: {:ok, arg}
      def handle_in(_data, state), do: {:ok, state}
      def handle_info(_msg, state), do: {:ok, state}
      def terminate(_reason, _state), do: :ok

      defoverridable init: 1, handle_in: 2, handle_info: 2, terminate: 2
    end
  end
end
