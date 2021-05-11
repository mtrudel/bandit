defmodule ConnectionHelpers do
  use ExUnit.CaseTemplate

  using do
    quote location: :keep do
      require Logger

      def http_server(_context) do
        {:ok, server_pid} =
          [plug: __MODULE__, options: [port: 0, transport_options: [ip: :loopback]]]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, port} = ThousandIsland.local_port(server_pid)
        [base: "http://localhost:#{port}", port: port]
      end

      def https_server(_context) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            scheme: :https,
            options: [
              port: 0,
              transport_options: [
                ip: :loopback,
                certfile: Path.join(__DIR__, "../support/cert.pem"),
                keyfile: Path.join(__DIR__, "../support/key.pem")
              ]
            ]
          ]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, port} = ThousandIsland.local_port(server_pid)
        [base: "https://localhost:#{port}", port: port]
      end

      def http1_client(_context), do: finch_for(:http1)
      def http2_client(_context), do: finch_for(:http2)

      defp finch_for(protocol) do
        finch_name = self() |> inspect() |> String.to_atom()

        opts = [
          name: finch_name,
          pools: %{
            default: [
              size: 50,
              count: 1,
              protocol: protocol,
              conn_opts: [
                transport_opts: [
                  verify: :verify_none,
                  cacertfile: Path.join(__DIR__, "../support/cert.pem")
                ]
              ]
            ]
          }
        ]

        {:ok, _} = start_supervised({Finch, opts})
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
