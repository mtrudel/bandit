defmodule HTTP1RequestTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use FinchHelpers

  setup :http_server
  setup :finch_http1_client

  describe "request handling" do
    test "reads a zero length body properly", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/expect_no_body", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_no_body(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ""
      send_resp(conn, 200, "OK")
    end

    test "reads a content-length encoded body properly", context do
      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_body",
          [{"connection", "close"}],
          String.duplicate("a", 8_000_000)
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_body(conn) do
      assert Plug.Conn.get_req_header(conn, "content-length") == ["8000000"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    test "reads a chunked body properly", context do
      stream = Stream.repeatedly(fn -> String.duplicate("a", 1_000_000) end) |> Stream.take(8)

      {:ok, response} =
        Finch.build(
          :post,
          context[:base] <> "/expect_chunked_body",
          [{"connection", "close"}],
          {:stream, stream}
        )
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_chunked_body(conn) do
      assert Plug.Conn.get_req_header(conn, "transfer-encoding") == ["chunked"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == String.duplicate("a", 8_000_000)
      send_resp(conn, 200, "OK")
    end

    test "reading request body multiple times works as expected", context do
      {:ok, response} =
        Finch.build(:post, context[:base] <> "/multiple_body_read", [], "OK")
        |> Finch.request(context[:finch_name])

      assert response.status == 200
    end

    def multiple_body_read(conn) do
      {:ok, body, conn} = read_body(conn)
      assert body == "OK"
      assert_raise(Bandit.BodyAlreadyReadError, fn -> read_body(conn) end)
      conn |> send_resp(200, body)
    end
  end

  describe "response handling" do
    test "writes out a response with no content-length header for 204 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_204", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 204
      assert response.body == ""
      assert is_nil(List.keyfind(response.headers, "content-length", 0))
    end

    def send_204(conn) do
      send_resp(conn, 204, "")
    end

    test "writes out a response with no content-length header for 3xx responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_301", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 301
      assert response.body == ""
      assert is_nil(List.keyfind(response.headers, "content-length", 0))
    end

    def send_301(conn) do
      send_resp(conn, 301, "")
    end

    test "writes out a response with zero content-length for 200 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_200")
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == ""
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "0"}
    end

    def send_200(conn) do
      send_resp(conn, 200, "")
    end

    test "writes out a response with zero content-length for 401 responses", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_401")
        |> Finch.request(context[:finch_name])

      assert response.status == 401
      assert response.body == ""
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "0"}
    end

    def send_401(conn) do
      send_resp(conn, 401, "")
    end

    test "writes out a chunked response", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_chunked_200", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"

      assert List.keyfind(response.headers, "transfer-encoding", 0) ==
               {"transfer-encoding", "chunked"}
    end

    def send_chunked_200(conn) do
      {:ok, conn} =
        conn
        |> send_chunked(200)
        |> chunk("OK")

      conn
    end

    test "writes out a sent file for the entire file with content length", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_full_file", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "ABCDEF"
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "6"}
    end

    def send_full_file(conn) do
      conn
      |> send_file(200, Path.join([__DIR__, "../../support/sendfile"]), 0, :all)
    end

    test "writes out a sent file for parts of a file with content length", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_file?offset=1&length=3", [
          {"connection", "close"}
        ])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "BCD"
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "3"}
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
  end
end
