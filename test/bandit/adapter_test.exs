defmodule Bandit.AdapterTest do
  use ExUnit.Case, async: true
  use ServerHelpers
  use ReqHelpers

  # Bandit.Adapter implements Plug.Conn.Adapter once, shared verbatim by both the HTTP/1 and
  # HTTP/2 stacks - its behaviour doesn't vary by protocol, so it's tested here against a single
  # (HTTP/1) server rather than duplicated per protocol.

  setup :http_server
  setup :req_http1_client

  describe "calling process validation" do
    test "raises if read_body is called from a process other than the stream owner", context do
      response = Req.post!(context.req, url: "/other_process_body_read", body: "OK")

      assert response.status == 200
    end

    def other_process_body_read(conn) do
      {:ok, "OK", conn} = read_body(conn)

      error =
        Task.async(fn ->
          try do
            read_body(conn)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if send_resp is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_resp")

      assert response.status == 200
    end

    def other_process_send_resp(conn) do
      error =
        Task.async(fn ->
          try do
            send_resp(conn, 200, "NOT OK")
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if send_chunked is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_chunked")

      assert response.status == 200
    end

    def other_process_send_chunked(conn) do
      error =
        Task.async(fn ->
          try do
            send_chunked(conn, 200)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if chunk is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_chunk")

      assert response.status == 200
    end

    def other_process_chunk(conn) do
      conn = send_chunked(conn, 200)

      error =
        Task.async(fn ->
          try do
            chunk(conn, "NOT OK")
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      {:ok, conn} = chunk(conn, "OK")
      conn
    end

    @tag :capture_log
    test "raises if send_file is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_send_file")

      assert response.status == 200
    end

    def other_process_send_file(conn) do
      error =
        Task.async(fn ->
          try do
            send_file(conn, 200, Path.join([__DIR__, "../support/sendfile"]), 0, :all)
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end

    @tag :capture_log
    test "raises if inform is called from a process other than the stream owner", context do
      response = Req.get!(context.req, url: "/other_process_inform")

      assert response.status == 200
    end

    def other_process_inform(conn) do
      error =
        Task.async(fn ->
          try do
            inform(conn, 100, [])
          rescue
            error -> error
          end
        end)
        |> Task.await()

      assert error == %RuntimeError{message: "Adapter functions must be called by stream owner"}

      send_resp(conn, 200, "OK")
    end
  end
end
