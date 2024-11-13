defmodule ServerTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers

  import ExUnit.CaptureLog

  test "server logs connection details at startup" do
    logs =
      capture_log(fn ->
        start_supervised({Bandit, plug: __MODULE__, port: 0, ip: :loopback})
      end)

    assert logs =~
             "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at 127.0.0.1"
  end

  test "startup_log: false arg disables connection detail log at startup" do
    logs =
      capture_log(fn ->
        start_supervised({Bandit, plug: __MODULE__, port: 0, ip: :loopback, startup_log: false})
      end)

    assert logs == ""
  end

  test "server logs connection error detail log at startup" do
    pid = start_supervised!({Bandit, scheme: :http, plug: __MODULE__, port: 40_000})
    {:ok, {address, port}} = ThousandIsland.listener_info(pid)

    logs =
      capture_log(fn ->
        assert {:error, _} = start_supervised({Bandit, plug: __MODULE__, port: port, ip: address})
      end)

    assert logs =~
             "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at http failed, port #{port} already in use"
  end

  test "special cases :inet option" do
    logs =
      capture_log(fn ->
        start_supervised({Bandit, [{:plug, __MODULE__}, :inet, {:port, 0}, {:ip, :loopback}]})
      end)

    assert logs =~ "at 127.0.0.1"
  end

  test "special cases :inet6 option" do
    logs =
      capture_log(fn ->
        start_supervised({Bandit, [{:plug, __MODULE__}, :inet6, {:port, 0}, {:ip, :loopback}]})
      end)

    assert logs =~ "at ::1"
  end

  test "can run multiple instances of Bandit" do
    start_supervised({Bandit, plug: __MODULE__, port: 40_000})
    start_supervised({Bandit, plug: __MODULE__, port: 40_001})

    assert 200 == Req.get!("http://localhost:40000/hello").status
    assert 200 == Req.get!("http://localhost:40001/hello").status
  end

  def hello(conn) do
    conn |> send_resp(200, "OK")
  end
end
