defmodule ClientHelpers do
  @moduledoc false

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
