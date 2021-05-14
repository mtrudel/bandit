defmodule ConnPipelineTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  describe "request handling" do
    setup :http_server
    setup :http1_client

    test "creates a conn with correct headers and requested metadata", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/expect_headers/a//b/c?abc=def", [
          {"X-Fruit", "banana"},
          {"connection", "close"}
        ])
        |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def expect_headers(conn) do
      assert conn.request_path == "/expect_headers/a//b/c"
      assert conn.path_info == ["expect_headers", "a", "b", "c"]
      assert conn.query_string == "abc=def"
      assert conn.method == "GET"
      assert conn.remote_ip == {127, 0, 0, 1}
      assert Plug.Conn.get_req_header(conn, "x-fruit") == ["banana"]
      send_resp(conn, 200, "OK")
    end

    @tag capture_log: true
    test "returns a 500 if the plug raises an exception", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/raise_error")
        |> Finch.request(context[:finch_name])

      assert response.status == 500
    end

    def raise_error(_conn) do
      raise "boom"
    end

    @tag capture_log: true
    test "returns a 400 if the request cannot be parsed", context do
      {:ok, client} = :gen_tcp.connect(:localhost, context[:port], active: false)
      :gen_tcp.send(client, "GET / HTTP/1.0\r\nGARBAGE\r\n\r\n")
      {:ok, response} = :gen_tcp.recv(client, 0)

      assert response == 'HTTP/1.0 400\r\n\r\n'
    end
  end
end
