defmodule Bandit.Plug do
  @moduledoc false

  @spec to_peer_data(ThousandIsland.Transport.socket_info(), :public_key.der_encoded() | nil) ::
          Plug.Conn.Adapter.peer_data()
  def to_peer_data({type, path}, cert) when type in [:local, :undefined],
    do: %{address: {type, path}, port: 0, ssl_cert: cert}

  def to_peer_data({:unspec, <<>>}, cert),
    do: %{address: :unspec, port: 0, ssl_cert: cert}

  def to_peer_data({ip, port}, cert), do: %{address: ip, port: port, ssl_cert: cert}
end
