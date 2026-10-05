defmodule HTTP1ErrorResponseTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  setup :http_server

  test "the default header-count limit still accepts exactly 50 headers", context do
    client = SimpleHTTP1Client.tcp_client(context)
    headers = for i <- 1..49, do: "header#{i}: foo"
    SimpleHTTP1Client.send(client, "GET", "/send_ok", ["host: localhost" | headers])

    assert {:ok, "200 OK", _headers, "OK"} = SimpleHTTP1Client.recv_reply(client)
  end

  @tag :capture_log
  test "a pipelined header-count rejection sends its own 431 response", context do
    client = SimpleHTTP1Client.tcp_client(context)
    headers = for i <- 1..50, do: "header#{i}: foo\r\n"

    Transport.send(client, [
      "GET /send_ok HTTP/1.1\r\nhost: localhost\r\n\r\n",
      "GET /never_dispatch HTTP/1.1\r\nhost: localhost\r\n",
      headers,
      "\r\n"
    ])

    response = recv_until_closed(client)
    assert response =~ "HTTP/1.1 200 OK\r\n"
    assert response =~ "431 Request Header Fields Too Large\r\n"
    assert length(Regex.scan(~r/HTTP\/1\.[01] \d{3}/, response)) == 2

    assert_receive {:log, %{level: :error, msg: {:string, msg}}}, 500
    assert msg == "** (Bandit.HTTPError) Too many headers"
  end

  @tag :capture_log
  test "a pipelined malformed request sends its own 400 response", context do
    client = SimpleHTTP1Client.tcp_client(context)

    Transport.send(
      client,
      "GET /send_ok HTTP/1.1\r\nhost: localhost\r\n\r\nGARBAGE\r\n\r\n"
    )

    response = recv_until_closed(client)
    assert response =~ "HTTP/1.1 200 OK\r\n"
    assert response =~ "400 Bad Request\r\n"
    assert length(Regex.scan(~r/HTTP\/1\.[01] \d{3}/, response)) == 2
  end

  @tag :capture_log
  test "a pipelined plug exception sends its own 500 response", context do
    client = SimpleHTTP1Client.tcp_client(context)

    Transport.send(client, [
      "GET /send_ok HTTP/1.1\r\nhost: localhost\r\n\r\n",
      "GET /raise_error HTTP/1.1\r\nhost: localhost\r\n\r\n"
    ])

    response = recv_until_closed(client)
    assert response =~ "HTTP/1.1 200 OK\r\n"
    assert response =~ "HTTP/1.1 500 Internal Server Error\r\n"
    assert length(Regex.scan(~r/HTTP\/1\.[01] \d{3}/, response)) == 2
  end

  @tag :capture_log
  test "an exception after the current response does not send another response", context do
    client = SimpleHTTP1Client.tcp_client(context)

    Transport.send(client, [
      "GET /send_ok HTTP/1.1\r\nhost: localhost\r\n\r\n",
      "GET /send_then_raise HTTP/1.1\r\nhost: localhost\r\n\r\n"
    ])

    response = recv_until_closed(client)
    assert length(Regex.scan(~r/HTTP\/1\.1 200 OK\r\n/, response)) == 2
    refute response =~ "500 Internal Server Error"
  end

  for status <- [400, 408, 414, 418, 431, 500] do
    @status status
    @tag :capture_log
    test "an empty #{@status} error response has explicit zero-length framing", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/http_error/#{@status}", ["host: localhost"])

      assert {:ok, status, headers, ""} = SimpleHTTP1Client.recv_reply(client)
      assert status == "#{@status} #{Plug.Conn.Status.reason_phrase(@status)}"
      assert Keyword.get_values(headers, :"content-length") == ["0"]
      assert Keyword.get_values(headers, :connection) == ["close"]
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end
  end

  for status <- [103, 204, 304] do
    @status status
    @tag :capture_log
    test "an empty #{@status} response does not acquire error-body framing", context do
      client = SimpleHTTP1Client.tcp_client(context)
      SimpleHTTP1Client.send(client, "GET", "/http_error/#{@status}", ["host: localhost"])

      assert {:ok, status, headers, ""} = SimpleHTTP1Client.recv_reply(client)
      assert status == "#{@status} #{Plug.Conn.Status.reason_phrase(@status)}"
      refute Keyword.has_key?(headers, :"content-length")
      assert SimpleHTTP1Client.connection_closed_for_reading?(client)
    end
  end

  @tag :capture_log
  test "a parser rejection is complete at the headers without waiting for EOF", context do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "localhost", context.port, mode: :passive, protocols: [:http1])

    on_exit(fn -> Mint.HTTP.close(conn) end)
    headers = for i <- 1..50, do: {"header#{i}", "foo"}
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/never_dispatch", headers, nil)
    {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)

    assert {:status, ref, 431} in responses
    assert {:done, ref} in responses
  end

  def send_ok(conn), do: send_resp(conn, 200, "OK")

  def never_dispatch(_conn), do: flunk("an over-limit request must not reach the plug")

  def raise_error(_conn), do: raise("test error")

  def send_then_raise(conn) do
    send_resp(conn, 200, "OK")
    raise("test error after response")
  end

  def http_error(conn) do
    raise Bandit.HTTPError,
      message: "test error",
      plug_status: conn.path_info |> List.last() |> String.to_integer()
  end

  defp recv_until_closed(client, response \\ "") do
    case Transport.recv(client, 0) do
      {:ok, data} -> recv_until_closed(client, response <> data)
      {:error, :closed} -> response
    end
  end
end
