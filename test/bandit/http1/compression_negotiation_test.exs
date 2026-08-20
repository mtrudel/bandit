defmodule HTTP1CompressionNegotiationTest do
  use ExUnit.Case, async: true
  use ServerHelpers

  setup :http_server

  def hello(conn), do: send_resp(conn, 200, String.duplicate("a", 10_000))

  defp get_with_accept_encoding(context, accept_encoding) do
    client = SimpleHTTP1Client.tcp_client(context)

    SimpleHTTP1Client.send(client, "GET", "/hello", [
      "host: localhost",
      "accept-encoding: #{accept_encoding}"
    ])

    {:ok, "200 OK", headers, body} = SimpleHTTP1Client.recv_reply(client)
    {Keyword.get(headers, :"content-encoding"), body}
  end

  test "compresses for a q-valued accept-encoding (Ruby net/http style)", context do
    {encoding, body} =
      get_with_accept_encoding(context, "gzip;q=1.0,deflate;q=0.6,identity;q=0.3")

    assert encoding == "gzip"
    assert :zlib.gunzip(body) == String.duplicate("a", 10_000)
  end

  test "compresses for an uppercase coding", context do
    {encoding, _body} = get_with_accept_encoding(context, "GZIP")
    assert encoding == "gzip"
  end

  test "honors a q=0 refusal end to end", context do
    {encoding, body} = get_with_accept_encoding(context, "gzip;q=0, x-gzip;q=0, deflate;q=0")
    assert encoding == nil
    assert body == String.duplicate("a", 10_000)
  end

  test "plain accept-encoding lists behave exactly as before", context do
    {encoding, body} = get_with_accept_encoding(context, "gzip, deflate")
    assert encoding == "gzip"
    assert :zlib.gunzip(body) == String.duplicate("a", 10_000)
  end
end
