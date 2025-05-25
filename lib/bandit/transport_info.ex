defmodule Bandit.TransportInfo do
  @moduledoc false

  @spec conn_info(ThousandIsland.Socket.t()) :: Bandit.Pipeline.conn_info()
  def conn_info(socket) do
    secure? = ThousandIsland.Socket.secure?(socket)

    {peer_address, _port} =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, peername} -> map_address(peername)
        {:error, reason} -> transport_error!("Unable to obtain conn_info", reason)
      end

    {secure?, peer_address}
  end

  @spec peer_data(ThousandIsland.Socket.t()) :: Plug.Conn.Adapter.peer_data()
  def peer_data(socket) do
    with {:ok, peername} <- ThousandIsland.Socket.peername(socket),
         {address, port} <- map_address(peername),
         {:ok, ssl_cert} <- peercert(socket) do
      %{address: address, port: port, ssl_cert: ssl_cert}
    else
      {:error, reason} -> transport_error!("Unable to obtain peer_data", reason)
    end
  end

  defp map_address(address) do
    case address do
      {:local, path} -> {{:local, path}, 0}
      {:unspec, <<>>} -> {:unspec, 0}
      {:undefined, term} -> {{:undefined, term}, 0}
      {ip, port} -> {ip, port}
    end
  end

  defp peercert(socket) do
    case ThousandIsland.Socket.peercert(socket) do
      {:ok, cert} -> {:ok, cert}
      {:error, :no_peercert} -> {:ok, nil}
      {:error, :not_secure} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_error!(message, error) do
    raise Bandit.TransportError, message: message, error: error
  end
end
