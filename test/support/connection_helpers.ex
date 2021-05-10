defmodule ConnectionHelpers do
  use ExUnit.CaseTemplate

  using do
    quote do
      require Logger

      def http_server(_context) do
        opts = [port: 0, transport_options: [ip: :loopback]]
        {:ok, server_pid} = start_supervised(Bandit.child_spec(plug: __MODULE__, options: opts))
        {:ok, port} = ThousandIsland.local_port(server_pid)
        [base: "http://localhost:#{port}", port: port]
      end

      def http1_client(_context) do
        finch_name = self() |> inspect() |> String.to_atom()

        {:ok, _} =
          start_supervised(
            {Finch, name: finch_name, pools: %{default: [size: 50, count: 1, protocol: :http1]}}
          )

        [finch_name: finch_name]
      end

      def init(opts) do
        opts
      end

      def call(conn, []) do
        function = String.to_atom(List.first(conn.path_info))

        try do
          apply(__MODULE__, function, [conn])
        rescue
          exception ->
            Logger.error(Exception.format(:error, exception, __STACKTRACE__))
            reraise(exception, __STACKTRACE__)
        end
      end
    end
  end
end
