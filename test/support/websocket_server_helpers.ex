defmodule WebSocketServerHelpers do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote location: :keep do
      @behaviour Sock

      alias Bandit.WebSocket.{Frame, Socket}

      def http1_websocket_server(context) do
        {:ok, server_pid} =
          [
            plug: {__MODULE__, %{startup_opts: :ok}},
            sock: {__MODULE__, %{startup_opts: :ok}},
            options: [port: 0, read_timeout: 1000, transport_options: [ip: :loopback]]
          ]
          |> Bandit.child_spec()
          |> start_supervised()

        {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)
        [base: "http://localhost:#{port}", port: port, server_pid: server_pid]
      end

      @impl Sock
      def init(opts), do: Map.put(opts, :init_opts, :ok)

      @impl Sock
      def negotiate(conn, opts) do
        conn = Plug.Conn.fetch_query_params(conn)

        calls =
          ~w(negotiate handle_connection handle_text_frame handle_binary_frame handle_ping_frame handle_pong_frame handle_close handle_error handle_timeout handle_info)a
          |> Enum.map(fn call_name ->
            function_name =
              conn.query_params
              |> Map.get(to_string(call_name), "noop_#{call_name}")
              |> String.to_atom()

            {call_name, function_name}
          end)
          |> Enum.into(%{})

        opts = Map.merge(opts, calls)

        apply(__MODULE__, calls[:negotiate], [conn, opts])
      end

      def noop_negotiate(conn, opts), do: {:accept, conn, opts, []}

      @impl Sock
      def handle_connection(socket, opts) do
        function = Map.get(opts, :handle_connection)
        apply(__MODULE__, function, [socket, opts])
      end

      def noop_handle_connection(_socket, opts), do: {:continue, opts}

      @impl Sock
      def handle_text_frame(data, socket, opts) do
        function = Map.get(opts, :handle_text_frame)
        apply(__MODULE__, function, [data, socket, opts])
      end

      def noop_handle_text_frame(_data, _socket, opts), do: {:continue, opts}

      @impl Sock
      def handle_binary_frame(data, socket, opts) do
        function = Map.get(opts, :handle_binary_frame)
        apply(__MODULE__, function, [data, socket, opts])
      end

      def noop_handle_binary_frame(_data, _socket, opts), do: {:continue, opts}

      @impl Sock
      def handle_ping_frame(data, socket, opts) do
        function = Map.get(opts, :handle_ping_frame)
        apply(__MODULE__, function, [data, socket, opts])
      end

      def noop_handle_ping_frame(_data, _socket, opts), do: {:continue, opts}

      @impl Sock
      def handle_pong_frame(data, socket, opts) do
        function = Map.get(opts, :handle_pong_frame)
        apply(__MODULE__, function, [data, socket, opts])
      end

      def noop_handle_pong_frame(_data, _socket, opts), do: {:continue, opts}

      @impl Sock
      def handle_close(reason, socket, opts) do
        function = Map.get(opts, :handle_close)
        apply(__MODULE__, function, [reason, socket, opts])
      end

      def noop_handle_close(_reason, _socket, _opts), do: :ok

      @impl Sock
      def handle_error(reason, socket, opts) do
        function = Map.get(opts, :handle_error)
        apply(__MODULE__, function, [reason, socket, opts])
      end

      def noop_handle_error(_reason, _socket, _opts), do: :ok

      @impl Sock
      def handle_timeout(socket, opts) do
        function = Map.get(opts, :handle_timeout)
        apply(__MODULE__, function, [socket, opts])
      end

      def noop_handle_timeout(_socket, _opts), do: :ok

      @impl Sock
      def handle_info(msg, socket, opts) do
        function = Map.get(opts, :handle_info)
        apply(__MODULE__, function, [msg, socket, opts])
      end

      def noop_handle_info(_msg, _socket, opts), do: {:continue, opts}

      def call(conn, _) do
        function = String.to_atom(List.first(conn.path_info))
        apply(__MODULE__, function, [conn])
      end
    end
  end
end
