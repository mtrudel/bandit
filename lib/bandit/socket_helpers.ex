defmodule Bandit.SocketHelpers do
  @moduledoc false
  # Conveniences for dealing with Thousand Island sockets

  @spec peer_data(ThousandIsland.Socket.t()) ::
          {:ok, Plug.Conn.Adapter.peer_data()} | {:error, term()}
  def peer_data(socket) do
    with {:ok, name} <- ThousandIsland.Socket.peername(socket),
         {:ok, cert} <- peer_cert(socket) do
      case name do
        {:local, path} -> {:ok, %{address: {:local, path}, port: 0, ssl_cert: cert}}
        {:unspec, <<>>} -> {:ok, %{address: :unspec, port: 0, ssl_cert: cert}}
        {:undefined, term} -> {:ok, %{address: {:undefined, term}, port: 0, ssl_cert: cert}}
        {ip, port} -> {:ok, %{address: ip, port: port, ssl_cert: cert}}
      end
    end
  end

  @spec peer_cert(ThousandIsland.Socket.t()) ::
          {:ok, :public_key.der_encoded() | nil} | {:error, term()}
  defp peer_cert(socket) do
    case ThousandIsland.Socket.peercert(socket) do
      {:ok, cert} -> {:ok, cert}
      {:error, :no_peercert} -> {:ok, nil}
      {:error, :not_secure} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
