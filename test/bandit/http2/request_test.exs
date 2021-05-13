defmodule HTTP2RequestTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  setup :https_server
  setup :http2_client

  describe "request handling" do
    @tag :skip
    test "it should run hello world", context do
      {:ok, response} =
        Finch.build(:get, context[:base] <> "/hello_world") |> Finch.request(context[:finch_name])

      assert response.status == 200
      assert response.body == "OK"
    end

    def hello_world(conn) do
      send_resp(conn, 200, "OK")
    end
  end
end
