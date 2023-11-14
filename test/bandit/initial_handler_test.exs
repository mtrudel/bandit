defmodule InitialHandlerTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  import ExUnit.CaptureLog

  def report_version(conn) do
    body = "#{get_http_protocol(conn)} #{conn.scheme}"
    send_resp(conn, 200, body)
  end

  describe "disabling protocols requests" do
    test "closes connection on HTTP/1 request if so configured", context do
      context = http_server(context, http_1_options: [enabled: false])
      client = SimpleHTTP1Client.tcp_client(context)

      SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: banana"])
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end

    test "refuses connection on HTTP/2 request if so configured", context do
      context = https_server(context, http_2_options: [enabled: false])

      assert {:error, {:tls_alert, {:no_application_protocol, _}}} =
               :ssl.connect(~c"localhost", context[:port],
                 active: false,
                 mode: :binary,
                 nodelay: true,
                 verify: :verify_peer,
                 cacertfile: Path.join(__DIR__, "../support/ca.pem"),
                 alpn_advertised_protocols: ["h2"]
               )
    end
  end

  describe "HTTP/1.x handling over TCP" do
    setup :http_server
    setup :req_http1_client

    test "sets up the HTTP 1.x handler", context do
      assert "HTTP/1.1 http" == Req.get!(context.req, url: "/report_version").body
    end
  end

  describe "HTTP/1.x handling over SSL" do
    setup :https_server
    setup :req_http1_client

    test "sets up the HTTP 1.x handler", context do
      assert "HTTP/1.1 https" == Req.get!(context.req, url: "/report_version").body
    end

    @tag :capture_log
    test "closes with an error if HTTP/1.1 is attempted over an h2 ALPN connection", context do
      socket = SimpleH2Client.tls_client(context)
      Transport.send(socket, "GET / HTTP/1.1\r\n")
      assert Transport.recv(socket, 0) == {:error, :closed}
    end
  end

  describe "HTTP/2 handling over TCP" do
    setup :http_server
    setup :req_h2_client

    test "sets up the HTTP/2 handler", context do
      assert "HTTP/2 http" == Req.get!(context.req, url: "/report_version").body
    end
  end

  describe "HTTP/2 handling over SSL" do
    setup :https_server
    setup :req_h2_client

    test "sets up the HTTP/2 handler", context do
      assert "HTTP/2 https" == Req.get!(context.req, url: "/report_version").body
    end

    @tag :capture_log
    test "closes with an error if HTTP2 is attempted over a HTTP/1.1 connection", context do
      socket = Transport.tls_client(context, ["http/1.1"])
      Transport.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert Transport.recv(socket, 0) == {:error, :closed}
    end
  end

  describe "unknown protocols" do
    setup :http_server
    setup :req_http1_client

    test "TLS connection is made to a TCP server", context do
      warnings =
        capture_log(fn ->
          base_url = String.replace_prefix(context.req.options.base_url, "http", "https")
          _ = Req.get(context.req, url: "/report_version", base_url: base_url)

          Process.sleep(250)
        end)

      assert warnings =~ "Connection that looks like TLS received on a clear channel"
    end
  end
end
