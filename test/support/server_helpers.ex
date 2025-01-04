defmodule ServerHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      import Plug.Conn

      require LoggerHelpers
      require TelemetryHelpers

      def http_server(context, opts \\ []) do
        [
          plug: __MODULE__,
          scheme: :http,
          port: 0,
          ip: :loopback,
          thousand_island_options: [read_timeout: 100]
        ]
        |> start_server(opts)
      end

      def https_server(context, opts \\ []) do
        [
          plug: __MODULE__,
          scheme: :https,
          port: 0,
          ip: :loopback,
          certfile: Path.join(__DIR__, "../support/cert.pem") |> Path.expand(),
          keyfile: Path.join(__DIR__, "../support/key.pem") |> Path.expand(),
          thousand_island_options: [read_timeout: 100]
        ]
        |> start_server(opts)
      end

      defp start_server(config, opts) do
        {:ok, server_pid} =
          config
          |> Keyword.merge(opts)
          |> Bandit.child_spec()
          |> start_supervised()

        TelemetryHelpers.attach_all_events(__MODULE__) |> on_exit()
        LoggerHelpers.receive_all_log_events(__MODULE__)

        {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)
        [base: "#{config[:scheme]}://localhost:#{port}", port: port, server_pid: server_pid]
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
