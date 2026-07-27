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

  describe "unknown message logging" do
    def report_pid(conn) do
      send_resp(conn, 200, self() |> :erlang.term_to_binary() |> Base.encode64())
    end

    # :logger automatically attaches the sending process's pid to every log event's
    # metadata, so we can target just our own handler process's messages - this mirrors
    # LoggerHelpers, but filters on pid rather than the (absent, for this particular log
    # call) `plug` metadata key.
    def log(%{meta: %{pid: pid}} = log_event, %{config: %{pid: test_pid, handler_pid: pid}}),
      do: send(test_pid, {:log, log_event})

    def log(_log_event, _config), do: :ok

    test "does not log unknown messages by default", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/report_pid", ["host: localhost"])
      {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      handler_pid = body |> Base.decode64!() |> :erlang.binary_to_term()

      ref = make_ref() |> inspect() |> String.to_atom()
      :logger.add_handler(ref, __MODULE__, %{config: %{pid: self(), handler_pid: handler_pid}})

      # Keep-alive keeps the underlying connection (and its handler process) alive; the
      # socket is still open at this point, so this message is delivered to a live process
      send(handler_pid, :some_unknown_message)

      # http_server/1 (called by the setup block) also registers its own LoggerHelpers
      # handler for this module's plug, which forwards unrelated log events (e.g. this
      # server's own startup announcement) to this same mailbox as {:log, _} - so this
      # must match on the specific shape we're checking for the absence of, not just the
      # {:log, _} envelope
      refute_receive {:log, %{msg: {:report, %{label: {GenServer, :no_handle_info}}}}}, 200
      :logger.remove_handler(ref)
    end

    test "logs unknown messages if so configured", context do
      context =
        context
        |> http_server(http_1_options: [log_unknown_messages: true])
        |> Enum.into(context)

      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/report_pid", ["host: localhost"])
      {:ok, "200 OK", _headers, body} = SimpleHTTP1Client.recv_reply(client)
      handler_pid = body |> Base.decode64!() |> :erlang.binary_to_term()

      ref = make_ref() |> inspect() |> String.to_atom()
      :logger.add_handler(ref, __MODULE__, %{config: %{pid: self(), handler_pid: handler_pid}})

      send(handler_pid, :some_unknown_message)

      # See the comment in the "does not log unknown messages by default" test above for
      # why this needs to match on more than just the {:log, _} envelope
      assert_receive {:log,
                      %{msg: {:report, %{label: {GenServer, :no_handle_info}}}} = log_event},
                     500

      :logger.remove_handler(ref)

      assert {:report,
              %{
                label: {GenServer, :no_handle_info},
                report: %{module: Bandit.HTTP1.Handler, message: :some_unknown_message}
              }} = log_event.msg
    end
  end
end
