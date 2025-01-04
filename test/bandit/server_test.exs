defmodule ServerTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  require LoggerHelpers

  test "server logs connection details at startup" do
    LoggerHelpers.receive_all_log_events(__MODULE__)
    Process.sleep(100)

    start_supervised({Bandit, plug: __MODULE__, port: 0, ip: :loopback})

    assert_receive {:log, %{level: :info, msg: {:string, msg}}}, 500
    assert msg =~ "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at 127.0.0.1"
  end

  test "startup_log: false arg disables connection detail log at startup" do
    LoggerHelpers.receive_all_log_events(__MODULE__)
    start_supervised({Bandit, plug: __MODULE__, port: 0, ip: :loopback, startup_log: false})

    refute_receive {:log, _}
  end

  @tag :capture_log
  test "server logs connection error detail log at startup" do
    LoggerHelpers.receive_all_log_events(__MODULE__)
    Process.sleep(100)

    {:ok, {address, port}} =
      start_supervised!({Bandit, scheme: :http, plug: __MODULE__, port: 0})
      |> ThousandIsland.listener_info()

    assert {:error, _} = start_supervised({Bandit, plug: __MODULE__, port: port, ip: address})

    assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500

    assert IO.iodata_to_binary(msg) =~
             "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at http failed, port #{port} already in use"
  end

  test "special cases :inet option" do
    LoggerHelpers.receive_all_log_events(__MODULE__)
    Process.sleep(100)

    start_supervised({Bandit, [{:plug, __MODULE__}, :inet, {:port, 0}, {:ip, :loopback}]})

    assert_receive {:log, %{level: :info, msg: {:string, msg}}}, 500
    assert msg =~ "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at 127.0.0.1"
  end

  test "special cases :inet6 option" do
    LoggerHelpers.receive_all_log_events(__MODULE__)
    Process.sleep(100)

    start_supervised({Bandit, [{:plug, __MODULE__}, :inet6, {:port, 0}, {:ip, :loopback}]})

    assert_receive {:log, %{level: :info, msg: {:string, msg}}}, 500
    assert msg =~ "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at ::1"
  end

  test "can run multiple instances of Bandit" do
    {:ok, {_address1, port1}} =
      start_supervised!({Bandit, plug: __MODULE__, port: 0})
      |> ThousandIsland.listener_info()

    {:ok, {_address2, port2}} =
      start_supervised!({Bandit, plug: __MODULE__, port: 0})
      |> ThousandIsland.listener_info()

    assert 200 == Req.get!("http://localhost:#{port1}/hello").status
    assert 200 == Req.get!("http://localhost:#{port2}/hello").status
  end

  def hello(conn) do
    conn |> send_resp(200, "OK")
  end
end
