defmodule WebsocketAutobahnTest do
  use ExUnit.Case, async: false

  @moduletag :external_conformance
  @moduletag timeout: 600_000

  @tag capture_log: true
  test "autobahn test suite" do
    defmodule EchoSock do
      @behaviour Sock

      import Sock.Socket
      import Plug.Conn

      @impl Sock
      def sock_init(_args) do
        []
      end

      @impl Sock
      def sock_negotiate(conn, state) do
        {:accept, conn, state, []}
      end

      @impl Sock
      def sock_handle_connection(_socket, state) do
        {:continue, state}
      end

      @impl Sock
      def sock_handle_text_frame(text, socket, state) do
        send_text_frame(socket, text)
        {:continue, state}
      end

      @impl Sock
      def sock_handle_binary_frame(binary, socket, state) do
        send_binary_frame(socket, binary)
        {:continue, state}
      end

      @impl Sock
      def sock_handle_ping_frame(_ping, _socket, state) do
        {:continue, state}
      end

      @impl Sock
      def sock_handle_pong_frame(_pong, _socket, state) do
        {:continue, state}
      end

      @impl Sock
      def sock_handle_close(_reason, _socket, _state) do
        :ok
      end

      @impl Sock
      def sock_handle_error(_error, _socket, _state) do
        :ok
      end

      @impl Sock
      def sock_handle_timeout(_socket, _state) do
        :ok
      end

      @impl Sock
      def sock_handle_info(_msg, _socket, state) do
        {:continue, state}
      end

      def init(_args) do
        []
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
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "-v",
          "#{Path.join(__DIR__, "../../support/autobahn_config.json")}:/fuzzingclient.json",
          "-v",
          "#{Path.join(__DIR__, "../../support/autobahn_reports")}:/reports"
        ] ++
          cmds() ++
          [
            "--name",
            "fuzzingclient",
            "crossbario/autobahn-testsuite",
            "wstest",
            "--mode",
            "fuzzingclient"
          ],
        stderr_to_stdout: true
      )

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
      |> Enum.sort_by(fn {code, _, _} -> code end)

    assert failures == []
  end

  if :os.type() == {:unix, :linux} do
    defp cmds do
      ["--add-host=host.docker.internal:host-gateway"]
    end
  else
    defp cmds do
      []
    end
  end
end
