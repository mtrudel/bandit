defmodule HTTP2RequestTest do
  use ConnectionHelpers, async: true

  import ExUnit.CaptureLog

  setup :https_server

  describe "request handling" do
    @tag :pending
    test "it should handle cases where the request arrives in small chunks" do
      # TODO - write out a request one byte at a time and ensure that it returns as expected
      # We can't test for this until we get a complete end to end request working
    end
  end

  describe "malformed requests" do
    test "closes with an error if the HTTP/2 connection preface is not present", context do
      errors =
        capture_log(fn ->
          {:ok, client} =
            :ssl.connect(:localhost, context[:port],
              active: false,
              verify: :verify_none,
              cacertfile: Path.join(__DIR__, "../../support/cert.pem"),
              alpn_advertised_protocols: ["h2"]
            )

          :ssl.send(client, "PRI * NOPE/2.0\r\n\r\nSM\r\n\r\n")
          {:error, :closed} = :ssl.recv(client, 0)

          # Let the server shut down so we don't log the error
          Process.sleep(100)
        end)

      assert errors =~ "Did not receive expected HTTP/2 connection preface"
    end

    @tag :pending
    test "it should ignore unknown frame types" do
      # TODO - write out an invalid frame type and ensure that we continue to work thereafter
      # We can't test for this until we get a complete end to end request working
    end

    @tag :pending
    test "it should shut down the connection gracefully when encountering a connection error" do
      # TODO - write out an invalid SETTINGS frame and ensure that we see a GOAWAY frame with an
      # appropriate error code
      # We can't test for this until we get a complete end to end request working
    end
  end
end
