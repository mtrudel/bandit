defmodule HTTP2ProtocolTest do
  use ConnectionHelpers, async: true

  import ExUnit.CaptureLog

  setup :https_server

  describe "frame splitting / merging" do
    test "it should handle cases where the request arrives in small chunks", context do
      socket = tls_client(context)

      # Send connection preface, client settings & ping frame one byte at a time
      ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
         <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      |> Stream.unfold(fn
        <<>> -> nil
        <<byte::binary-size(2), rest::binary>> -> {byte, rest}
      end)
      |> Enum.each(fn byte -> :ssl.send(socket, byte) end)

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end

    test "it should handle cases where multiple frames arrive in the same packet", context do
      socket = tls_client(context)

      # Send connection preface, client settings & ping frame all in one
      :ssl.send(
        socket,
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <>
          <<0, 0, 0, 4, 0, 0, 0, 0, 0>> <> <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>
      )

      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  describe "errors and unexpected frames" do
    test "it should ignore unknown frame types", context do
      socket = setup_connection(context)

      errors =
        capture_log(fn ->
          :ssl.send(socket, <<0, 0, 0, 254, 0, 0, 0, 0, 0>>)

          # Let the server shut down so we don't log the error
          Process.sleep(100)
        end)

      assert connection_alive?(socket)
      assert errors =~ "Unknown frame"
    end

    @tag :pending
    test "it should shut down the connection gracefully when encountering a connection error" do
      # TODO - write out an invalid SETTINGS frame and ensure that we see a GOAWAY frame with an
      # appropriate error code
      # We can't test for this until we get a complete end to end request working
    end
  end

  describe "connection preface handling" do
    test "closes with an error if the HTTP/2 connection preface is not present", context do
      errors =
        capture_log(fn ->
          socket = tls_client(context)
          :ssl.send(socket, "PRI * NOPE/2.0\r\n\r\nSM\r\n\r\n")
          {:error, :closed} = :ssl.recv(socket, 0)

          # Let the server shut down so we don't log the error
          Process.sleep(100)
        end)

      assert errors =~ "Did not receive expected HTTP/2 connection preface"
    end

    test "the server should send a SETTINGS frame at start of the connection", context do
      socket = tls_client(context)
      :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>}
    end
  end

  describe "SETTINGS frames" do
    test "the server should acknowledge a client's SETTINGS frames", context do
      socket = tls_client(context)
      exchange_prefaces(socket)
      :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
      assert :ssl.recv(socket, 9) == {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>}
    end
  end

  describe "PING frames" do
    test "the server should acknowledge a client's PING frames", context do
      socket = setup_connection(context)
      :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
      assert :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
    end
  end

  def tls_client(context) do
    {:ok, socket} =
      :ssl.connect(:localhost, context[:port],
        active: false,
        mode: :binary,
        verify: :verify_none,
        cacertfile: Path.join(__DIR__, "../../support/cert.pem"),
        alpn_advertised_protocols: ["h2"]
      )

    socket
  end

  def setup_connection(context) do
    socket = tls_client(context)
    exchange_prefaces(socket)
    exchange_client_settings(socket)
    socket
  end

  def exchange_prefaces(socket) do
    :ssl.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    {:ok, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>} = :ssl.recv(socket, 9)
    :ssl.send(socket, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>)
  end

  def exchange_client_settings(socket) do
    :ssl.send(socket, <<0, 0, 0, 4, 0, 0, 0, 0, 0>>)
    {:ok, <<0, 0, 0, 4, 1, 0, 0, 0, 0>>} = :ssl.recv(socket, 9)
  end

  def connection_alive?(socket) do
    :ssl.send(socket, <<0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>)
    :ssl.recv(socket, 17) == {:ok, <<0, 0, 8, 6, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8>>}
  end
end
