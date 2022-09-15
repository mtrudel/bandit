defmodule WebsocketAutobahnTest do
  use ExUnit.Case, async: false

  @tag timeout: :infinity
  @tag :autobahn
  test "autobahn test suite" do
    defmodule EchoSock do
      @behaviour Sock

      import Sock.Socket
      import Plug.Conn

      @impl Sock
      def init(_args) do
        []
      end

      @impl Sock
      def negotiate(conn, state) do
        {:accept, conn, state}
      end

      @impl Sock
      def handle_connection(_socket, state) do
        {:continue, state}
      end

      @impl Sock
      def handle_text_frame(text, socket, state) do
        send_text_frame(socket, text)
        {:continue, state}
      end

      @impl Sock
      def handle_binary_frame(binary, socket, state) do
        send_binary_frame(socket, binary)
        {:continue, state}
      end

      @impl Sock
      def handle_ping_frame(_ping, _socket, state) do
        {:continue, state}
      end

      @impl Sock
      def handle_pong_frame(_pong, _socket, state) do
        {:continue, state}
      end

      @impl Sock
      def handle_close(_status_code, _socket, _state) do
        :ok
      end

      @impl Sock
      def handle_error(_error, _socket, _state) do
        :ok
      end

      @impl Sock
      def handle_timeout(_socket, _state) do
        :ok
      end

      def call(conn, _) do
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "Hello world")
      end
    end

    Bandit.child_spec(
      sock: EchoSock,
      plug: EchoSock
    )
    |> start_supervised!()

    {_, 0} =
      System.cmd("docker", [
        "run",
        "--rm",
        "-v",
        "#{Path.join(__DIR__, "../../support/autobahn_config.json")}:/fuzzingclient.json",
        "-v",
        "#{Path.join(__DIR__, "../../support/autobahn_reports")}:/reports",
        "--name",
        "fuzzingclient",
        "crossbario/autobahn-testsuite",
        "wstest",
        "--mode",
        "fuzzingclient"
      ])

    failures =
      Path.join(__DIR__, "../../support/autobahn_reports/servers/index.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("bandit")
      |> Enum.map(fn {test_case, %{"behavior" => res, "behaviorClose" => res_close}} ->
        {test_case, res, res_close}
      end)
      |> Enum.reject(fn {_, res, res_close} ->
        (res == "OK" or res == "NON-STRICT" or res == "INFORMATIONAL") and
          (res_close == "OK" or res_close == "INFORMATIONAL")
      end)

    assert failures == []
  end
end
