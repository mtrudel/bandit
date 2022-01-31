defmodule InitialHandlerTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use FinchHelpers

  def report_version(conn) do
    body = "#{get_http_protocol(conn)} #{conn.scheme}"
    send_resp(conn, 200, body)
  end

  describe "HTTP/1.x handling over TCP" do
    setup :http_server
    setup :finch_http1_client

    test "sets up the HTTP 1.x handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/1.1 http"
    end
  end

  describe "HTTP/1.x handling over SSL" do
    setup :https_server
    setup :finch_http1_client

    test "sets up the HTTP 1.x handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/1.1 https"
    end

    test "closes with an error if HTTP/1.1 is attempted over an h2 ALPN connection", context do
      socket = SimpleH2Client.tls_client(context)
      :ssl.send(socket, "GET / HTTP/1.1\r\n")
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end
  end

  describe "HTTP/2 handling over TCP" do
    setup :http_server
    setup :finch_h2_client

    test "sets up the HTTP/2 handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/2 http"
    end
  end

  describe "HTTP/2 handling over SSL" do
    setup :https_server
    setup :finch_h2_client

    test "sets up the HTTP/2 handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/2 https"
    end

    test "closes with an error if HTTP2 is attempted over a HTTP/1.1 connection", context do
      socket = ClientHelpers.tls_client(context, ["http/1.1"])
      :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 0) == {:error, :closed}
    end
  end
end
