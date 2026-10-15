defmodule Bandit.SocketHelpers do
  @moduledoc false

  def iodata_empty?(""), do: true
  def iodata_empty?([]), do: true
  def iodata_empty?([head | tail]), do: iodata_empty?(head) and iodata_empty?(tail)
  def iodata_empty?(_), do: false

  @spec conn_data(ThousandIsland.Socket.t()) :: Bandit.Pipeline.conn_data()
  def conn_data(socket) do
    secure? = ThousandIsland.Socket.secure?(socket)

    # Thousand Island captures the peername when it accepts the connection, so this still works if
    # the client has already closed or reset it (which is the whole point of doing it this way; a
    # live lookup would fail here with :enotconn / :einval and crash the connection process)
    {:ok, peername} = ThousandIsland.Socket.peername(socket)
    {peer_address, _port} = map_address(peername)

    {secure?, peer_address}
  end

  @spec peer_data(ThousandIsland.Socket.t()) :: Plug.Conn.Adapter.peer_data()
  def peer_data(socket) do
    {:ok, peername} = ThousandIsland.Socket.peername(socket)
    {address, port} = map_address(peername)

    case peercert(socket) do
      {:ok, ssl_cert} -> %{address: address, port: port, ssl_cert: ssl_cert}
      {:error, reason} -> transport_error!("Unable to obtain peer_data", reason)
    end
  end

  @spec sock_data(ThousandIsland.Socket.t()) :: Plug.Conn.Adapter.sock_data()
  def sock_data(socket) do
    with {:ok, sockname} <- ThousandIsland.Socket.sockname(socket),
         {address, port} <- map_address(sockname) do
      %{address: address, port: port}
    else
      {:error, reason} -> transport_error!("Unable to obtain sock_data", reason)
    end
  end

  @spec ssl_data(ThousandIsland.Socket.t()) :: Plug.Conn.Adapter.ssl_data()
  def ssl_data(socket) do
    case ThousandIsland.Socket.connection_information(socket) do
      {:ok, connection_information} -> connection_information
      {:error, :not_secure} -> nil
      {:error, reason} -> transport_error!("Unable to obtain ssl_data", reason)
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

  @spec transport_error!(term(), term()) :: no_return()
  defp transport_error!(message, error) do
    raise Bandit.TransportError, message: message, error: error
  end
end
