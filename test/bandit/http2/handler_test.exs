defmodule HTTP2HandlerTest do
  use ExUnit.Case, async: true

  # The GenServer callbacks of the handler rescue errors raised by the connection and stop the
  # process. A stop must be a three element tuple; a bare {:stop, reason} is a bad return value to
  # GenServer, which turns a clean close into a crash report carrying the whole connection state
  describe "stopping on an error raised in a callback" do
    setup do
      LoggerHelpers.receive_all_log_events(__MODULE__)
      :ok
    end

    # A nil connection makes any Bandit.HTTP2.Connection call raise, which stands in for the
    # errors these clauses rescue in practice
    @state %{connection: nil, opts: %{http: [], http_2: []}, plug: {__MODULE__, []}}

    @tag :capture_log
    test "handle_info stops with a valid stop tuple" do
      assert {:stop, {:shutdown, :local_closed}, {:socket, @state}} =
               Bandit.HTTP2.Handler.handle_info(
                 {{:send_headers, [], false}, 1},
                 {:socket, @state}
               )

      assert_receive {:log, %{level: :error}}, 500
    end

    @tag :capture_log
    test "handle_call stops with a valid stop tuple" do
      assert {:stop, {:shutdown, :local_closed}, {:socket, @state}} =
               Bandit.HTTP2.Handler.handle_call(
                 {{:send_data, [], "", true}, 1},
                 {self(), make_ref()},
                 {:socket, @state}
               )

      assert_receive {:log, %{level: :error}}, 500
    end
  end
end
