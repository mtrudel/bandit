defmodule HTTP1LoggingTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  require Logger

  setup :http_server
  setup :req_http1_client

  describe "protocol error logging" do
    @tag :capture_log
    test "errors are short logged by default", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.HTTPError) Header read HTTP error: \"GARBAGE\\r\\n\""
    end

    @tag :capture_log
    test "errors are verbosely logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (Bandit.HTTPError) Header read HTTP error: \"GARBAGE\\r\\n\""
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    test "errors are not logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: false])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      refute_receive {:log, %{level: :error}}
    end

    test "client closure protocol errors are not logged by default", context do
      context =
        context
        |> http_server(http_options: [log_protocol_errors: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      refute_receive {:log, %{level: :error}}
    end

    @tag :capture_log
    test "client closure protocol errors are short logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :short])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg == "** (Bandit.TransportError) Unrecoverable error: closed"
    end

    @tag :capture_log
    test "client closure protocol errors are verbosely logged if so configured", context do
      context =
        context
        |> http_server(http_options: [log_client_closures: :verbose])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/sleep_and_send", ["host: localhost"])
      Process.sleep(20)
      Transport.close(client)

      assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
      assert msg =~ "** (Bandit.TransportError) Unrecoverable error: closed"
      assert msg =~ "lib/bandit/pipeline.ex:"
    end

    @tag :capture_log
    test "it should provide useful metadata to logger handler", context do
      client = SimpleHTTP1Client.tcp_client(context)
      Transport.send(client, "GET / HTTP/1.1\r\nGARBAGE\r\n\r\n")
      assert {:ok, "400 Bad Request", _headers, <<>>} = SimpleHTTP1Client.recv_reply(client)

      assert_receive {:log, log_event}, 500

      assert %{
               meta: %{
                 domain: [:elixir, :bandit],
                 crash_reason:
                   {%Bandit.HTTPError{message: "Header read HTTP error: \"GARBAGE\\r\\n\""},
                    [_ | _] = _stacktrace},
                 plug: {__MODULE__, []}
               }
             } = log_event
    end

    def sleep_and_send(conn) do
      Process.sleep(100)

      conn = send_resp(conn, 200, "IMPOSSIBLE")

      Logger.error("IMPOSSIBLE")
      conn
    end
  end
end
