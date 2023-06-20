defmodule Bandit.Plug do
  @moduledoc false

  def to_peer_data({:local, path}, cert),
    do: %{address: {:local, path}, port: 0, ssl_cert: cert}

  def to_peer_data({:unspec, <<>>}, cert),
    do: %{address: :unspec, port: 0, ssl_cert: cert}

  def to_peer_data({:undefined, term}, cert),
    do: %{address: {:undefined, term}, port: 0, ssl_cert: cert}

  def to_peer_data({ip, port}, cert), do: %{address: ip, port: port, ssl_cert: cert}
end
