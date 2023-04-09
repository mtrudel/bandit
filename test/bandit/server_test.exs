defmodule ServerTest do
  # False due to capture log emptiness check
  use ExUnit.Case, async: false
  use ServerHelpers
  use FinchHelpers

  import ExUnit.CaptureLog

  setup :finch_http1_client

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
    pid = start_supervised!({Bandit, scheme: :http, plug: __MODULE__})
    {:ok, %{address: address, port: port}} = ThousandIsland.listener_info(pid)

    logs =
      capture_log(fn ->
        assert {:error, _} = start_supervised({Bandit, plug: __MODULE__, port: port, ip: address})
      end)

    assert logs =~
             "Running ServerTest with Bandit #{Application.spec(:bandit)[:vsn]} at http failed, port already in use"
  end

  test "can run multiple instances of Bandit", context do
    start_supervised({Bandit, plug: __MODULE__, port: 4000})

    start_supervised({Bandit, plug: __MODULE__, port: 4001})

    {:ok, response} =
      Finch.build(:get, "http://localhost:4000/hello")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"

    {:ok, response} =
      Finch.build(:get, "http://localhost:4001/hello")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def hello(conn) do
    conn |> send_resp(200, "OK")
  end
end
