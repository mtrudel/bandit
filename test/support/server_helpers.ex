defmodule ServerHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      import Plug.Conn

      def http_server(context, opts \\ []) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            port: 0,
            ip: :loopback,
            thousand_island_options: [read_timeout: 1000]
          ]
          |> Keyword.merge(opts)
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)
        [base: "http://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def https_server(context, opts \\ []) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            scheme: :https,
            port: 0,
            ip: :loopback,
            certfile: Path.join(__DIR__, "../support/cert.pem") |> Path.expand(),
            keyfile: Path.join(__DIR__, "../support/key.pem") |> Path.expand(),
            thousand_island_options: [read_timeout: 1000]
          ]
          |> Keyword.merge(opts)
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)
        [base: "https://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def init(opts) do
        opts
      end

      def call(conn, []) do
        function = String.to_atom(List.first(conn.path_info))
        apply(__MODULE__, function, [conn])
      end

      defoverridable init: 1, call: 2
    end
  end
end
