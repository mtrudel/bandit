defmodule NoopWebSock do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      @behaviour WebSock

      @impl true
      def init(arg), do: {:ok, arg}

      @impl true
      def handle_in(_data, state), do: {:ok, state}

      @impl true
      def handle_info(_msg, state), do: {:ok, state}

      @impl true
      def terminate(_reason, _state), do: :ok

      defoverridable init: 1, handle_in: 2, handle_info: 2, terminate: 2
    end
  end
end
