defmodule ConnectionHelpers do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Bitwise

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
                  verify: :verify_peer,
                  cacertfile: Path.join(__DIR__, "../support/ca.pem")
                ]
              ]
            ]
          }
        ]

        {:ok, _} = start_supervised({Finch, opts})
        [finch_name: finch_name]
      end

      def tls_client(context) do
        {:ok, socket} =
          :ssl.connect('localhost', context[:port],
            active: false,
            mode: :binary,
            verify: :verify_peer,
            cacertfile: Path.join(__DIR__, "../support/ca.pem"),
            alpn_advertised_protocols: ["h2"]
          )

        socket
      end

      def setup_connection(context) do
        socket = tls_client(context)
        exchange_prefaces(socket)
        exchange_client_settings(socket)
        socket
      end

      def exchange_prefaces(socket) do
        :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>} = :ssl.recv(socket, 9)
        :ssl.send(socket, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)
      end

      def exchange_client_settings(socket) do
        :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
        {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>} = :ssl.recv(socket, 9)
      end

      def connection_alive?(socket) do
        :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
        :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
      end

      def simple_send_headers(socket, stream_id, end_stream, headers) do
        ctx = HPack.Table.new(4096)
        {:ok, _, headers} = HPack.encode(headers, ctx)
        flags = if end_stream, do: 0x05, else: 0x04

        :ssl.send(socket, [
          <<byte_size(headers)::24, 1::8, flags::8, 0::1, stream_id::31>>,
          headers
        ])
      end

      def successful_response?(socket, stream_id, end_stream) do
        {:ok, ^stream_id, ^end_stream, [{":status", "200"} | _]} = simple_read_headers(socket)
      end

      def simple_read_headers(socket) do
        {:ok, <<length::24, 1::8, flags::8, 0::1, stream_id::31>>} = :ssl.recv(socket, 9)
        {:ok, header_block} = :ssl.recv(socket, length)
        ctx = HPack.Table.new(4096)
        {:ok, _, headers} = HPack.decode(header_block, ctx)
        {:ok, stream_id, (flags &&& 0x01) == 0x01, headers}
      end

      def simple_send_body(socket, stream_id, end_stream, body) do
        flags = if end_stream, do: 0x01, else: 0x00
        :ssl.send(socket, [<<byte_size(body)::24, 0::8, flags::8, 0::1, stream_id::31>>, body])
      end

      def simple_read_body(socket) do
        {:ok, <<body_length::24, 0::8, flags::8, 0::1, stream_id::31>>} = :ssl.recv(socket, 9)

        if body_length == 0 do
          {:ok, stream_id, (flags &&& 0x01) == 0x01, <<>>}
        else
          {:ok, body} = :ssl.recv(socket, body_length)
          {:ok, stream_id, (flags &&& 0x01) == 0x01, body}
        end
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
