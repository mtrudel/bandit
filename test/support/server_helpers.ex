defmodule ServerHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      import Plug.Conn

      def http_server(context) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            options: [port: 0, read_timeout: 1000, transport_options: [ip: :loopback]]
          ]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)
        [base: "http://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def https_server(context) do
        {:ok, server_pid} =
          [
            plug: __MODULE__,
            scheme: :https,
            options: [
              port: 0,
              read_timeout: 1000,
              transport_options: [
                ip: :loopback,
                certfile: Path.join(__DIR__, "../support/cert.pem"),
                keyfile: Path.join(__DIR__, "../support/key.pem")
              ]
            ]
          ]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)
        [base: "https://localhost:#{port}", port: port, server_pid: server_pid]
      end

      def init(opts) do
        opts
      end

      def call(conn, []) do
        function =
          if conn.path_info == ["*"] do
            :global_options
          else
            conn.path_info
            |> List.first()
            |> String.to_existing_atom()
          end

        apply(__MODULE__, function, [conn])
      end

      defoverridable init: 1, call: 2
    end
  end
end
