defmodule Bandit.HTTP3.AltSvcTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers
  use Machete

  # ---------------------------------------------------------------------------
  # Test setup helpers
  # ---------------------------------------------------------------------------

  # Start an HTTPS server with HTTP/3 advertised on `h3_port`.
  # Returns {:ok, kw} with :base, :port, :h3_port, :server_pid for ExUnit to merge.
  defp https_with_h3(h3_port, extra_opts \\ []) do
    opts =
      [
        plug: __MODULE__,
        scheme: :https,
        port: 0,
        ip: :loopback,
        certfile: Path.join(__DIR__, "../../support/cert.pem") |> Path.expand(),
        keyfile: Path.join(__DIR__, "../../support/key.pem") |> Path.expand(),
        thousand_island_options: [read_timeout: 500],
        http_3_options: [enabled: true, port: h3_port]
      ] ++ extra_opts

    {:ok, server_pid} = opts |> Bandit.child_spec() |> start_supervised()
    {:ok, {_ip, port}} = Bandit.listener_info(server_pid)
    base = "https://localhost:#{port}"

    {:ok, base: base, port: port, h3_port: h3_port, server_pid: server_pid}
  end

  def ok_handler(conn) do
    send_resp(conn, 200, "ok")
  end

  # ---------------------------------------------------------------------------
  # HTTP/1.1 responses include alt-svc
  # ---------------------------------------------------------------------------

  describe "HTTP/1.1 responses advertise HTTP/3" do
    setup do
      TelemetryHelpers.attach_all_events(__MODULE__) |> on_exit()
      LoggerHelpers.receive_all_log_events(__MODULE__)
      https_with_h3(9443)
    end

    setup :req_http1_client

    test "alt-svc header is present on a 200 response", context do
      response = Req.get!(context.req, url: "/ok_handler")
      assert response.status == 200
      [alt_svc] = Req.Response.get_header(response, "alt-svc")
      assert alt_svc == "h3=\":9443\"; ma=86400"
    end

    test "alt-svc header contains the correct H3 port", context do
      response = Req.get!(context.req, url: "/ok_handler")
      [alt_svc] = Req.Response.get_header(response, "alt-svc")
      assert alt_svc =~ ~r{h3=":9443"}
      assert alt_svc =~ ~r{ma=\d+}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP/2 responses include alt-svc
  # ---------------------------------------------------------------------------

  describe "HTTP/2 responses advertise HTTP/3" do
    setup do
      TelemetryHelpers.attach_all_events(__MODULE__) |> on_exit()
      LoggerHelpers.receive_all_log_events(__MODULE__)
      https_with_h3(9444)
    end

    setup :req_h2_client

    test "alt-svc header is present on a 200 response", context do
      response = Req.get!(context.req, url: "/ok_handler")
      assert response.status == 200
      [alt_svc] = Req.Response.get_header(response, "alt-svc")
      assert alt_svc == "h3=\":9444\"; ma=86400"
    end
  end

  # ---------------------------------------------------------------------------
  # No alt-svc when HTTP/3 is not enabled
  # ---------------------------------------------------------------------------

  describe "HTTP/3 disabled" do
    setup :https_server
    setup :req_http1_client

    test "no alt-svc header when http_3_options not set", context do
      response = Req.get!(context.req, url: "/ok_handler")
      assert response.status == 200
      assert Req.Response.get_header(response, "alt-svc") == []
    end
  end

  # ---------------------------------------------------------------------------
  # Different H3 port from TCP port
  # ---------------------------------------------------------------------------

  describe "custom H3 port" do
    setup do
      TelemetryHelpers.attach_all_events(__MODULE__) |> on_exit()
      LoggerHelpers.receive_all_log_events(__MODULE__)
      https_with_h3(9445)
    end

    setup :req_http1_client

    test "alt-svc uses the H3 port, not the HTTPS port", context do
      response = Req.get!(context.req, url: "/ok_handler")
      [alt_svc] = Req.Response.get_header(response, "alt-svc")
      # H3 port (9445) differs from TCP port (random ephemeral)
      assert alt_svc == "h3=\":9445\"; ma=86400"
      refute alt_svc =~ ":#{context.port}"
    end
  end
end
