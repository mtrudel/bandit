defmodule ClientHelpers do
  @moduledoc false

  def tcp_client(context) do
    {:ok, socket} = :gen_tcp.connect('localhost', context[:port], active: false, mode: :binary)

    socket
  end

  def tls_client(context, protocols) do
    {:ok, socket} =
      :ssl.connect('localhost', context[:port],
        active: false,
        mode: :binary,
        verify: :verify_peer,
        cacertfile: Path.join(__DIR__, "../support/ca.pem"),
        alpn_advertised_protocols: protocols
      )

    socket
  end
end
