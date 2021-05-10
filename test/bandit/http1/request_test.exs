defmodule HTTP1RequestTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  setup :http_server
  setup :http1_client

  describe "request handling" do
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
  end

  describe "response handling" do
    test "writes out a response with no body", context do
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

    test "writes out a response with a content-length header", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/send_200", [{"connection", "close"}])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
      assert List.keyfind(response.headers, "content-length", 0) == {"content-length", "2"}
    end

    def send_200(conn) do
      send_resp(conn, 200, "OK")
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
