defmodule HTTP2PlugTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  setup :https_server
  setup :http2_client

  test "reading request headers", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/header_read_test", [{"X-Request-Header", "Request"}])
      |> Finch.request(context[:finch_name])

    assert response.status == 200
  end

  def header_read_test(conn) do
    assert get_req_header(conn, "x-request-header") == ["Request"]

    conn |> send_resp(200, <<>>)
  end

  @tag :skip
  test "reading request body", _context do
    # TODO land body reading in 0.3.1
  end

  test "writing response headers", context do
    {:ok, response} =
      Finch.build(:head, context[:base] <> "/header_write_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200

    assert response.headers == [
             {"cache-control", "max-age=0, private, must-revalidate"},
             {"X-Response-Header", "Response"}
           ]
  end

  def header_write_test(conn) do
    conn
    |> put_resp_header("X-Response-Header", "Response")
    |> send_resp(200, <<>>)
  end

  test "sending a body", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/body_test") |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def body_test(conn) do
    conn |> send_resp(200, "OK")
  end

  test "lazy sending a body", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/lazy_body_test")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OK"
  end

  def lazy_body_test(conn) do
    conn |> resp(200, "OK")
  end

  test "sending a chunk", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/chunk_test") |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "OKOK"
  end

  def chunk_test(conn) do
    conn
    |> send_chunked(200)
    |> chunk("OK")
    |> elem(1)
    |> chunk("OK")
    |> elem(1)
  end

  test "writes out a sent file for the entire file", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/send_full_file")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "ABCDEF"
  end

  def send_full_file(conn) do
    conn
    |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
  end

  test "writes out a sent file for parts of a file", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/send_file?offset=1&length=3")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "BCD"
  end

  def send_file(conn) do
    conn = fetch_query_params(conn)

    conn
    |> send_file(
      200,
      Path.join([__DIR__, "../../support/sendfile"]),
      String.to_integer(conn.params["offset"]),
      String.to_integer(conn.params["length"])
    )
  end

  @tag :skip
  test "sending informational responses", _context do
    # TODO land inform support in 0.3.4
  end

  @tag :skip
  test "server push messages", _context do
    # TODO land push support in 0.3.5
  end

  test "reading HTTP version", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/report_version")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == "HTTP/2"
  end

  def report_version(conn) do
    send_resp(conn, 200, conn |> get_http_protocol() |> to_string())
  end

  test "reading peer data", context do
    {:ok, response} =
      Finch.build(:get, context[:base] <> "/peer_data")
      |> Finch.request(context[:finch_name])

    assert response.status == 200
    assert response.body == inspect(%{address: {127, 0, 0, 1}, ssl_cert: nil})
  end

  def peer_data(conn) do
    # Drop port as we have no way of asking Finch for our local port
    send_resp(conn, 200, conn |> get_peer_data() |> Map.take([:address, :ssl_cert]) |> inspect())
  end
end
