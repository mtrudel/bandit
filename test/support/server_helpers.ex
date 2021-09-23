defmodule ServerHelpers do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote location: :keep do
      import Plug.Conn

      def http_server(context) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            read_timeout: 1000,
            options: [port: 0, transport_options: [ip: :loopback]]
          ]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, port} = ThousandIsland.local_port(server_pid)
        [base: "http://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def https_server(context) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            scheme: :https,
            read_timeout: 1000,
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
        [base: "https://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def init(opts) do
        opts
      end

      def call(conn, []) do
        function = String.to_atom(List.first(conn.path_info))
        apply(__MODULE__, function, [conn])
      end
    end
  end
end
