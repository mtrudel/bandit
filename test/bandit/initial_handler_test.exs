defmodule InitialHandlerTest do
  use ConnectionHelpers, async: true

  import Plug.Conn

  def report_version(conn) do
    send_resp(conn, 200, conn |> get_http_protocol() |> to_string())
  end

  describe "HTTP 1.x handling" do
    setup :http_server
    setup :http1_client

    test "sets up the HTTP 1.x handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/1.1"
    end
  end

  describe "HTTP/2 handling" do
    setup :https_server
    setup :http2_client

    @tag :skip
    test "sets up the HTTP/2 handler", %{base: base, finch_name: finch_name} do
      {:ok, response} = Finch.build(:get, base <> "/report_version") |> Finch.request(finch_name)

      assert response.status == 200
      assert response.body == "HTTP/2"
    end
  end
end
