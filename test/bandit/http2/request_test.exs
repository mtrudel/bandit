defmodule HTTP2RequestTest do
  use ConnectionHelpers, async: true

  import ExUnit.CaptureLog

  setup :https_server

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
  end
end
